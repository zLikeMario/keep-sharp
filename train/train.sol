// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Version pinned so Remix's npm resolver can find the package; Foundry remaps the same prefix to
// the local lib (see remappings.txt). Both toolchains compile this single source unchanged.
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts@1.3.0/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts@1.3.0/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title Train Fire Game (EVM)
/// @notice A configurable on-chain game that mints ticket NFTs and settles rewards on random hits.
/// @dev Randomness comes from Chainlink VRF v2.5. A play does NOT resolve in the same transaction:
/// `play()` reserves a ticket and requests a random word; the coordinator later calls
/// `fulfillRandomWords`, which assigns the number and checks for a hit. Only one randomness request
/// is in flight at a time, so the game stays serialized (like the existing hit lock). This removes
/// the same-transaction predictability/grinding that pure on-chain entropy is vulnerable to.
contract TrainGame is VRFConsumerBaseV2Plus {
    uint256 private constant BPS = 10_000;
    bytes4 private constant ERC20_TRANSFER_SELECTOR = 0xa9059cbb;
    bytes4 private constant ERC20_TRANSFER_FROM_SELECTOR = 0x23b872dd;
    bytes4 private constant ERC20_BALANCE_OF_SELECTOR = 0x70a08231;

    // Fixed-point scale for the entry/withdraw curve coefficients (parts per million).
    uint256 private constant CURVE_SCALE = 1_000_000;

    // Reward fee (1%) taken from each reward payout and sent directly to a fixed recipient.
    uint256 public constant REWARD_FEE_BPS = 100;
    address public constant FEE_RECIPIENT = 0x888813D61Ad10161Be6480D88573dDf808558888;

    // If a VRF request is never fulfilled, the initiator (or owner) can cancel it after this long and
    // recover the staked funds, so a stuck oracle can never permanently freeze the game.
    uint256 public constant REQUEST_TIMEOUT = 1 hours;

    address public settlementToken;

    // Game configuration
    uint256 public randomRange; // b: random number count, generated values are [0, b - 1]
    uint256 public sqrtRange; // s = floor(sqrt(b)), the collision-zone scale
    uint256 public baseEntryAmount; // a: one whole default token in its smallest unit
    uint256 public lockDuration; // default: 5 minutes

    // Upper bound on simultaneously active carriages. Bounds every list scan (hit search, settlement
    // sums, range removal) so they can never exceed the block / VRF callback gas limit. 0 = unlimited.
    uint256 public maxActiveTickets;

    // When the owner closes the round no new plays are allowed and active players may reclaim stake.
    bool public closed;

    // Accounting
    uint256 public totalPool;
    // Sum of all unclaimed pendingRewards, so the owner sweep can never touch funds owed to players.
    uint256 public totalPendingRewards;

    // Minimal NFT-like ticket data
    string public name = "Train Game Ticket";
    string public symbol = "TGT";
    uint256 public totalSupply; // current occupied slot count
    uint256 public nextTicketId; // monotonically increasing NFT id

    enum TicketStatus {
        None,
        Active,
        Removed,
        Withdrawn,
        Invalid,
        Pending // staked, awaiting its VRF number; not yet minted or in the active list
    }

    struct Ticket {
        uint256 id;
        address player;
        uint256 position; // sequence number (starts from 1)
        uint256 randomNumber;
        uint256 stakeAmount; // remaining principal still in pool
        bool principalWithdrawn;
        TicketStatus status;
        uint256 secondGuessNumber; // the second-guess number when this ticket was voided by a miss
    }

    struct HitLock {
        bool active;
        uint256 deadline;
        uint256 hitTicketId;
        uint256 targetTicketId;
        address hitPlayer;
        bool secondGuessUsed;
        bool secondGuessSucceeded;
        uint256 secondGuessNumber;
        uint256 rewardAmount;
    }

    HitLock public hitLock;

    // NFT ownership (non-transferable ticket NFT)
    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;

    // Ticket storage
    mapping(uint256 => Ticket) public tickets;
    uint256[] public activeTicketIds;
    // Number -> the single Active ticket currently holding it (0 = none). The game settles a hit the
    // instant a second active ticket draws an existing number, so each number maps to at most one
    // active ticket; this makes hit detection O(1) instead of scanning the whole active list.
    mapping(uint256 => uint256) public activeTicketIdByNumber;

    // Withdraw ledgers
    mapping(address => uint256) public pendingRewards;

    // Reentrancy guard
    uint256 private _entered;

    // ------------------------------
    // Chainlink VRF v2.5 configuration (owner-set after deploy, so nothing chain-specific is hardcoded)
    // ------------------------------
    bytes32 public vrfKeyHash; // gas lane
    uint256 public vrfSubscriptionId; // 0 until configured
    uint16 public vrfRequestConfirmations = 3;
    // The callback's only O(active tickets) work is the settlement range-sum (~2.3k gas per carriage);
    // hit detection itself is O(1). This limit must stay consistent with maxActiveTickets or a
    // fulfillment could run out of gas. Defaults (callback 2.0M, cap 500) leave ample margin; raise
    // both together for a longer train, keeping under the chain's max callback gas.
    uint32 public vrfCallbackGasLimit = 2_000_000;
    bool public vrfNativePayment; // pay the VRF fee in native coin (true) or LINK (false)

    // ------------------------------
    // Single in-flight randomness request
    // ------------------------------
    enum RequestKind {
        None,
        Play,
        SecondGuess
    }

    uint256 public pendingRequestId; // 0 = no request in flight
    RequestKind public pendingKind;
    uint256 public pendingTicketId; // Play: the reserved ticket; SecondGuess: the hit ticket
    address public pendingPlayer;
    uint256 public pendingRequestedAt;

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 indexed tokenId
    );

    event PlayRequested(
        address indexed player,
        uint256 indexed ticketId,
        uint256 position,
        uint256 amount,
        uint256 requestId
    );
    event SecondGuessRequested(address indexed player, uint256 requestId);
    event RequestCancelled(
        uint256 indexed requestId,
        uint8 kind,
        address indexed player
    );

    event Played(
        address indexed player,
        uint256 indexed ticketId,
        uint256 position,
        uint256 randomNumber,
        uint256 amount
    );

    event HitOccurred(
        uint256 indexed hitTicketId,
        uint256 indexed targetTicketId,
        address indexed hitPlayer,
        address targetPlayer,
        uint256 middleAmount,
        uint256 deadline
    );

    event PrincipalWithdrawn(
        address indexed player,
        uint256 indexed ticketId,
        uint256 amount
    );
    event RewardClaimed(address indexed player, uint256 amount);
    event LockReleased(uint256 indexed hitTicketId, bool timeoutMarked);
    event SettlementFinalized(
        uint256 indexed hitTicketId,
        address indexed hitPlayer,
        address indexed targetPlayer,
        uint256 hitReward,
        uint256 targetReward,
        bool secondGuessSucceeded,
        bool timedOut
    );
    event SecondGuess(
        address indexed player,
        uint256 randomNumber,
        bool hit,
        uint256 targetTicketId,
        uint256 rewardAmount
    );
    event RewardFeePaid(address indexed recipient, uint256 amount);
    event RoundClosed();
    event StakeReclaimed(
        address indexed player,
        uint256 indexed ticketId,
        uint256 amount
    );
    event VrfConfigUpdated(
        bytes32 keyHash,
        uint256 subscriptionId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        bool nativePayment
    );
    event MaxActiveTicketsUpdated(uint256 maxActiveTickets);
    event TokensSwept(address indexed token, address indexed to, uint256 amount);

    error NotOwner();
    error Locked();
    error InvalidConfig();
    error InvalidToken();
    error TicketNotActive();
    error NotTicketOwner();
    error AlreadyWithdrawn();
    error NothingToClaim();
    error LockNotActive();
    error NotHitPlayer();
    error LockNotExpired();
    error AlreadySecondGuessed();
    error TokenTransferFailed();
    error GameClosed();
    error GameNotClosed();
    error RequestPending();
    error NoPendingRequest();
    error RequestNotStuck();
    error VrfNotConfigured();
    error RoundFull();
    error NotAuthorized();

    modifier nonReentrant() {
        if (_entered == 1) revert();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(
        address _settlementToken,
        uint256 _baseEntryAmount,
        uint256 _randomRange,
        uint256 _lockDuration,
        address _vrfCoordinator
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        if (_baseEntryAmount == 0) revert InvalidConfig();
        if (_randomRange < 2) revert InvalidConfig();
        if (_lockDuration == 0) revert InvalidConfig();

        settlementToken = _settlementToken;
        baseEntryAmount = _baseEntryAmount;
        randomRange = _randomRange;
        sqrtRange = _sqrt(_randomRange);
        lockDuration = _lockDuration;
        // Bounds the VRF callback's settlement range-sum; keep in step with vrfCallbackGasLimit.
        // Comfortably above the birthday collision threshold even for large ranges (e.g. b=10000 ~125).
        maxActiveTickets = 500;
    }

    /// @dev Integer square root (Babylonian). Used for the collision-zone scale s = floor(sqrt(b)).
    function _sqrt(uint256 n) internal pure returns (uint256) {
        if (n == 0) return 0;
        uint256 x = n;
        uint256 y = (x + 1) / 2;
        while (y < x) {
            x = y;
            y = (x + n / x) / 2;
        }
        return x;
    }

    // ------------------------------
    // Owner configuration
    // ------------------------------

    /// @notice Configure the Chainlink VRF subscription. Must be set (subscriptionId != 0) before any
    /// play can draw a number. The subscription is created off-chain, this contract added as consumer.
    function setVrfConfig(
        bytes32 keyHash,
        uint256 subscriptionId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        bool nativePayment
    ) external onlyOwner {
        if (requestConfirmations == 0 || callbackGasLimit == 0) revert InvalidConfig();
        vrfKeyHash = keyHash;
        vrfSubscriptionId = subscriptionId;
        vrfRequestConfirmations = requestConfirmations;
        vrfCallbackGasLimit = callbackGasLimit;
        vrfNativePayment = nativePayment;
        emit VrfConfigUpdated(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            nativePayment
        );
    }

    /// @notice Adjust the active-carriage cap (bounds all list scans). 0 disables the cap.
    function setMaxActiveTickets(uint256 newMax) external onlyOwner {
        maxActiveTickets = newMax;
        emit MaxActiveTicketsUpdated(newMax);
    }

    /// @notice Owner ends the round: no new plays are allowed afterwards, and active players can
    /// reclaim their original participation amount via reclaimStake.
    function closeGame() external onlyOwner nonReentrant {
        if (pendingRequestId != 0) revert RequestPending();
        _autoReleaseLockIfExpired();
        if (hitLock.active) revert Locked();
        if (closed) revert GameClosed();
        closed = true;
        emit RoundClosed();
    }

    /// @notice After the round is closed, an active ticket holder reclaims their full participation
    /// amount (no fee). Tickets that withdrew midway, lost a second guess, or were voided/settled
    /// are not Active and therefore cannot reclaim.
    function reclaimStake(uint256 ticketId) external nonReentrant {
        if (!closed) revert GameNotClosed();

        Ticket storage t = tickets[ticketId];
        if (t.status != TicketStatus.Active) revert TicketNotActive();
        if (t.player != msg.sender) revert NotTicketOwner();

        uint256 amount = t.stakeAmount;
        if (amount == 0) revert NothingToClaim();

        t.stakeAmount = 0;
        t.principalWithdrawn = true;
        t.status = TicketStatus.Withdrawn;
        _clearNumberIndex(ticketId, t.randomNumber);
        totalPool -= amount;
        _burn(ticketId);

        _safeTokenTransfer(msg.sender, amount);
        emit StakeReclaimed(msg.sender, ticketId, amount);
    }

    // ------------------------------
    // Views
    // ------------------------------

    function ownerOf(uint256 tokenId) external view returns (address) {
        address tokenOwner = _ownerOf[tokenId];
        require(tokenOwner != address(0), "NOT_MINTED");
        return tokenOwner;
    }

    function balanceOf(address account) external view returns (uint256) {
        require(account != address(0), "ZERO_ADDRESS");
        return _balanceOf[account];
    }

    function getActiveTicketIds() external view returns (uint256[] memory) {
        return activeTicketIds;
    }

    function getCurrentEntryAmount() public view returns (uint256) {
        return getEntryAmount(totalSupply + 1);
    }

    /// @notice Entry curve, derived from the birthday/collision economics.
    /// @dev The expected value of a seat is bathtub-shaped in the participation index x:
    /// front seats survive and win as targets, the cheapest seats sit at the collision
    /// zone x ~ sqrt(b), and rare deep seats are valuable again. The price multiplier is
    ///     phi(x) = clamp( 0.40 * (x^2 / b) + 0.57 * (s / x) - 0.40 , 0.40 , 6.0 )
    /// with a gentle early-advantage / late-disadvantage tilt
    ///     tilt(x) = 1 + 0.12 * (x - s) / (x + s)
    /// where s = floor(sqrt(b)). entry(x) = a * phi(x) * tilt(x). Tuned so the bulk's expected
    /// value runs ~1.05 early -> ~0.9 mid -> ~0.8 late (declining, FOMO), the cheapest tickets
    /// sit at x ~ sqrt(b), the front jackpot is bounded, and late stakes grow large (up to ~6x).
    /// All math is integer fixed-point at CURVE_SCALE (1e6); divisions round down.
    function getEntryAmount(
        uint256 participantIndex
    ) public view returns (uint256) {
        if (participantIndex == 0) revert InvalidConfig();
        return (baseEntryAmount * _entryMultiplier(participantIndex)) / CURVE_SCALE;
    }

    /// @dev Returns the entry price multiplier phi(x) * tilt(x), scaled by CURVE_SCALE.
    function _entryMultiplier(uint256 x) internal view returns (uint256) {
        uint256 b = randomRange;
        uint256 s = sqrtRange;

        // phi(x) = 0.40*x^2/b + 0.57*s/x - 0.40, clamped to [0.40, 6.0].
        uint256 positive = (40 * x * x * CURVE_SCALE) / (100 * b) +
            (57 * s * CURVE_SCALE) / (100 * x);
        uint256 offset = (40 * CURVE_SCALE) / 100;
        uint256 phi = positive > offset ? positive - offset : 0;

        uint256 lower = (40 * CURVE_SCALE) / 100;
        uint256 upper = (600 * CURVE_SCALE) / 100;
        if (phi < lower) phi = lower;
        if (phi > upper) phi = upper;

        // tilt(x) = 1 + 0.12 * (x - s) / (x + s); bounded to (0.88, 1.12).
        uint256 span = (12 * CURVE_SCALE) / 100;
        uint256 tilt;
        if (x >= s) {
            tilt = CURVE_SCALE + (span * (x - s)) / (x + s);
        } else {
            tilt = CURVE_SCALE - (span * (s - x)) / (x + s);
        }

        return (phi * tilt) / CURVE_SCALE;
    }

    /// @notice Withdraw curve: a fraction of the seat's entry price that shrinks as the seat
    /// gets "hotter" (closer to / inside the collision zone), so a player cannot dodge an
    /// imminent middle-loss by exiting.
    /// @dev withdraw(x) = entry(x) * (0.30 + 0.60 * R(x)), where R(x) = 2b / (2b + x^2) is a
    /// rational survival proxy (~1 at the cold front, ~0 deep). Always < entry(x).
    function getWithdrawAmount(
        uint256 participantIndex
    ) public view returns (uint256) {
        if (participantIndex == 0) revert InvalidConfig();

        uint256 twoB = 2 * randomRange;
        uint256 xSquared = participantIndex * participantIndex;
        uint256 factor = (30 * CURVE_SCALE) /
            100 +
            ((60 * CURVE_SCALE) / 100) *
            twoB /
            (twoB + xSquared);

        return (getEntryAmount(participantIndex) * factor) / CURVE_SCALE;
    }

    function getTicketWithdrawAmount(
        uint256 ticketId
    ) public view returns (uint256) {
        Ticket storage t = tickets[ticketId];
        if (
            t.id == 0 || t.principalWithdrawn || t.status != TicketStatus.Active
        ) return 0;

        uint256 amount = getWithdrawAmount(t.position);
        return amount > t.stakeAmount ? t.stakeAmount : amount;
    }

    // ------------------------------
    // Game flow
    // ------------------------------

    /// @notice Stake and request a random number. The ticket is reserved now; its number is assigned
    /// asynchronously in `fulfillRandomWords`. While a request is in flight the game is frozen.
    function play() external nonReentrant {
        if (pendingRequestId != 0) revert RequestPending();
        if (closed) revert GameClosed();
        _autoReleaseLockIfExpired();
        if (hitLock.active) revert Locked();
        if (vrfSubscriptionId == 0) revert VrfNotConfigured();
        if (maxActiveTickets != 0 && activeTicketIds.length >= maxActiveTickets) {
            revert RoundFull();
        }

        uint256 requiredAmount = getCurrentEntryAmount();

        uint256 ticketId = ++nextTicketId;
        uint256 position = totalSupply + 1;
        totalSupply = position;

        // Balance-delta accounting: credit exactly what arrived, so fee-on-transfer tokens cannot
        // desync totalPool from the real balance (which would otherwise strand later claimers).
        uint256 balanceBefore = _tokenBalance();
        _safeTokenTransferFrom(msg.sender, address(this), requiredAmount);
        uint256 received = _tokenBalance() - balanceBefore;
        totalPool += received;

        Ticket storage t = tickets[ticketId];
        t.id = ticketId;
        t.player = msg.sender;
        t.position = position;
        t.stakeAmount = received;
        t.principalWithdrawn = false;
        t.status = TicketStatus.Pending;

        uint256 requestId = _requestRandomWord();
        pendingRequestId = requestId;
        pendingKind = RequestKind.Play;
        pendingTicketId = ticketId;
        pendingPlayer = msg.sender;
        pendingRequestedAt = block.timestamp;

        emit PlayRequested(msg.sender, ticketId, position, received, requestId);
    }

    function withdrawPrincipal(uint256 ticketId) external nonReentrant {
        if (pendingRequestId != 0) revert RequestPending();
        if (closed) revert GameClosed();
        _autoReleaseLockIfExpired();
        if (hitLock.active) revert Locked();

        Ticket storage t = tickets[ticketId];
        if (t.status != TicketStatus.Active) revert TicketNotActive();
        if (t.player != msg.sender) revert NotTicketOwner();
        if (t.principalWithdrawn) revert AlreadyWithdrawn();

        uint256 amount = getTicketWithdrawAmount(ticketId);
        if (amount == 0) revert NothingToClaim();

        t.principalWithdrawn = true;
        t.status = TicketStatus.Withdrawn;
        _clearNumberIndex(ticketId, t.randomNumber);
        t.stakeAmount -= amount;
        totalPool -= amount;
        // Free the carriage slot: the next entry reuses this position/price. The residual stake
        // stays in the list (and pool) as a ghost, ordered by id between its neighbours, so a
        // later collision spanning it still includes the leftover amount in settlement.
        totalSupply -= 1;
        _burn(ticketId);

        _safeTokenTransfer(msg.sender, amount);
        emit PrincipalWithdrawn(msg.sender, ticketId, amount);
    }

    function claimReward() external nonReentrant {
        if (pendingRequestId != 0) revert RequestPending();
        _autoReleaseLockIfExpired();
        if (hitLock.active) revert Locked();

        uint256 amount = _consumeReward(msg.sender);
        if (amount == 0) revert NothingToClaim();

        _payReward(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    /// @dev Pays a reward, skimming REWARD_FEE_BPS (1%) directly to FEE_RECIPIENT. The full gross
    /// amount leaves the pool; the player receives the net and FEE_RECIPIENT the fee.
    function _payReward(address to, uint256 amount) internal {
        totalPool -= amount;
        uint256 fee = (amount * REWARD_FEE_BPS) / BPS;
        uint256 net = amount - fee;
        if (fee > 0) {
            _safeTokenTransfer(FEE_RECIPIENT, fee);
            emit RewardFeePaid(FEE_RECIPIENT, fee);
        }
        if (net > 0) _safeTokenTransfer(to, net);
    }

    /// @notice During lock window, the hit player can claim immediately and unlock the game.
    /// @dev The first被命中 player's half is allocated to pendingRewards so they can claim
    /// it independently later. A successful second guess is split with the FIRST target as well;
    /// the second-guess target only decided whether the guess succeeded.
    function hitPlayerClaimAndUnlock() external nonReentrant {
        if (pendingRequestId != 0) revert RequestPending();
        if (!hitLock.active) revert LockNotActive();
        if (msg.sender != hitLock.hitPlayer) revert NotHitPlayer();
        if (block.timestamp >= hitLock.deadline) revert LockNotExpired();

        uint256 hitTicketId = hitLock.hitTicketId;
        bool secondGuessSucceeded = hitLock.secondGuessSucceeded;

        (
            address hitPlayer,
            uint256 hitReward,
            address targetPlayer,
            uint256 targetReward
        ) = _splitAndRemoveSettlement();

        _creditReward(targetPlayer, targetReward);

        // The hit player's own previously-pending rewards plus this hit's share, paid out now.
        uint256 amount = _consumeReward(hitPlayer) + hitReward;
        if (amount == 0) revert NothingToClaim();

        _unlock(false);
        emit SettlementFinalized(
            hitTicketId,
            hitPlayer,
            targetPlayer,
            hitReward,
            targetReward,
            secondGuessSucceeded,
            false
        );
        _payReward(hitPlayer, amount);
        emit RewardClaimed(hitPlayer, amount);
    }

    /// @notice Hit player requests one second-guess draw during the lock. The outcome is resolved
    /// asynchronously in `fulfillRandomWords`.
    function secondGuess() external nonReentrant {
        if (pendingRequestId != 0) revert RequestPending();
        if (!hitLock.active) revert LockNotActive();
        if (msg.sender != hitLock.hitPlayer) revert NotHitPlayer();
        if (block.timestamp >= hitLock.deadline) revert LockNotExpired();
        if (hitLock.secondGuessUsed) revert AlreadySecondGuessed();

        uint256 requestId = _requestRandomWord();
        pendingRequestId = requestId;
        pendingKind = RequestKind.SecondGuess;
        pendingTicketId = hitLock.hitTicketId;
        pendingPlayer = msg.sender;
        pendingRequestedAt = block.timestamp;

        emit SecondGuessRequested(msg.sender, requestId);
    }

    /// @notice Only the hit player can explicitly release an expired lock.
    /// Other players can resume normal operations after timeout; those operations auto-release it.
    function releaseLockAfterTimeout() external {
        if (pendingRequestId != 0) revert RequestPending();
        if (!hitLock.active) revert LockNotActive();
        if (msg.sender != hitLock.hitPlayer) revert NotHitPlayer();
        if (block.timestamp < hitLock.deadline) revert LockNotExpired();
        _expireHitLock();
    }

    /// @notice Recover the stake from a VRF request that the coordinator never fulfilled. Callable by
    /// the initiating player or the owner once REQUEST_TIMEOUT has elapsed, so a stuck oracle cannot
    /// permanently freeze the game or trap funds. A late fulfillment afterwards is ignored.
    function cancelStuckRequest() external nonReentrant {
        uint256 requestId = pendingRequestId;
        if (requestId == 0) revert NoPendingRequest();
        if (block.timestamp < pendingRequestedAt + REQUEST_TIMEOUT) revert RequestNotStuck();
        if (msg.sender != pendingPlayer && msg.sender != owner()) revert NotAuthorized();

        RequestKind kind = pendingKind;
        uint256 ticketId = pendingTicketId;
        address player = pendingPlayer;
        _clearPending();

        if (kind == RequestKind.Play) {
            Ticket storage t = tickets[ticketId];
            if (t.status == TicketStatus.Pending) {
                uint256 refund = t.stakeAmount;
                t.stakeAmount = 0;
                t.status = TicketStatus.Removed;
                totalPool -= refund;
                totalSupply -= 1;
                if (refund > 0) _safeTokenTransfer(player, refund);
            }
        }
        // For a stuck second guess there is nothing to refund; clearing the request lets the lock
        // expire and settle the original hit normally.
        emit RequestCancelled(requestId, uint8(kind), player);
    }

    // ------------------------------
    // Chainlink VRF
    // ------------------------------

    function _requestRandomWord() internal returns (uint256) {
        return
            s_vrfCoordinator.requestRandomWords(
                VRFV2PlusClient.RandomWordsRequest({
                    keyHash: vrfKeyHash,
                    subId: vrfSubscriptionId,
                    requestConfirmations: vrfRequestConfirmations,
                    callbackGasLimit: vrfCallbackGasLimit,
                    numWords: 1,
                    extraArgs: VRFV2PlusClient._argsToBytes(
                        VRFV2PlusClient.ExtraArgsV1({nativePayment: vrfNativePayment})
                    )
                })
            );
    }

    /// @dev VRF callback. MUST NOT revert: it does only storage writes and emits (no token moves, no
    /// external calls), and ignores any request id that is not the one currently in flight.
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        if (requestId != pendingRequestId) return;

        RequestKind kind = pendingKind;
        uint256 ticketId = pendingTicketId;
        uint256 randomNumber = randomWords[0] % randomRange;

        // Clear the in-flight request first so the game unfreezes and this can't be double-processed.
        _clearPending();

        if (kind == RequestKind.Play) {
            _finalizePlay(ticketId, randomNumber);
        } else if (kind == RequestKind.SecondGuess) {
            _finalizeSecondGuess(randomNumber);
        }
    }

    function _finalizePlay(uint256 ticketId, uint256 randomNumber) internal {
        Ticket storage t = tickets[ticketId];
        // Defensive: only finalize a ticket still awaiting its number.
        if (t.status != TicketStatus.Pending) return;

        t.randomNumber = randomNumber;
        t.status = TicketStatus.Active;

        _mint(t.player, ticketId);
        activeTicketIds.push(ticketId);

        emit Played(t.player, ticketId, t.position, randomNumber, t.stakeAmount);

        uint256 targetTicketId = activeTicketIdByNumber[randomNumber];
        if (targetTicketId != 0) {
            // A second active ticket drew an existing number -> immediate hit. Neither end is left
            // registered as the number's holder; the settlement (claim/expire) clears the existing
            // entry when it removes the range.
            _handleHit(ticketId, targetTicketId);
        } else {
            activeTicketIdByNumber[randomNumber] = ticketId;
        }
    }

    function _finalizeSecondGuess(uint256 randomNumber) internal {
        // The lock could have settled while the request was outstanding; only resolve if still live.
        if (!hitLock.active || hitLock.secondGuessUsed) return;
        uint256 targetTicketId = _findAnyActiveTicketByRandom(randomNumber);
        _resolveSecondGuess(randomNumber, targetTicketId);
    }

    function _clearPending() internal {
        pendingRequestId = 0;
        pendingKind = RequestKind.None;
        pendingTicketId = 0;
        pendingPlayer = address(0);
        pendingRequestedAt = 0;
    }

    // ------------------------------
    // Internal settlement
    // ------------------------------

    function _creditReward(address to, uint256 amount) internal {
        if (amount == 0) return;
        pendingRewards[to] += amount;
        totalPendingRewards += amount;
    }

    function _consumeReward(address from) internal returns (uint256 amount) {
        amount = pendingRewards[from];
        if (amount > 0) {
            pendingRewards[from] = 0;
            totalPendingRewards -= amount;
        }
    }

    function _resolveSecondGuess(
        uint256 randomNumber,
        uint256 targetTicketId
    ) internal {
        hitLock.secondGuessUsed = true;
        hitLock.secondGuessNumber = randomNumber;
        bool success = targetTicketId != 0;
        if (success) {
            hitLock.secondGuessSucceeded = true;
            // Keep hitLock.targetTicketId as the FIRST被命中 ticket: the reward is split
            // with the first target. The second-guess target only validated the guess.
            hitLock.rewardAmount = _getOccupiedStakePool();
            hitLock.deadline = block.timestamp + lockDuration;
        }

        emit SecondGuess(
            hitLock.hitPlayer,
            randomNumber,
            success,
            targetTicketId,
            success ? hitLock.rewardAmount : 0
        );

        if (!success) {
            _invalidateHitTicket();
            _unlock(false);
        }
    }

    function _handleHit(uint256 hitTicketId, uint256 targetTicketId) internal {
        Ticket storage hitT = tickets[hitTicketId];
        Ticket storage targetT = tickets[targetTicketId];
        // Ordering keys off the monotonic ticket id, not position: withdrawn slots are reused
        // for entry pricing, so positions are no longer unique. The id range still spans every
        // carriage (including withdrawn residual ghosts) between the two ends, inclusive.
        uint256 middleAmount = _getTicketRangeStake(hitTicketId, targetTicketId);
        // Keep range tickets queryable while locked; claiming performs removal.
        hitLock = HitLock({
            active: true,
            deadline: block.timestamp + lockDuration,
            hitTicketId: hitTicketId,
            targetTicketId: targetTicketId,
            hitPlayer: hitT.player,
            secondGuessUsed: false,
            secondGuessSucceeded: false,
            secondGuessNumber: 0,
            rewardAmount: middleAmount
        });

        emit HitOccurred(
            hitTicketId,
            targetTicketId,
            hitT.player,
            targetT.player,
            middleAmount,
            hitLock.deadline
        );
    }

    function _unlock(bool timeoutMarked) internal {
        uint256 hitTicketId = hitLock.hitTicketId;
        delete hitLock;
        emit LockReleased(hitTicketId, timeoutMarked);
    }

    function _autoReleaseLockIfExpired() internal {
        if (hitLock.active && block.timestamp >= hitLock.deadline) {
            _expireHitLock();
        }
    }

    /// @notice Timeout path: the hit player took no action before the deadline.
    /// @dev The settlement is still finalized so BOTH the hit player and the first被命中
    /// player keep their share as independently-claimable pendingRewards, and the命中区间
    /// tickets are removed from the active list (so they leave the pool and the table).
    function _expireHitLock() internal {
        uint256 hitTicketId = hitLock.hitTicketId;
        bool secondGuessSucceeded = hitLock.secondGuessSucceeded;

        (
            address hitPlayer,
            uint256 hitReward,
            address targetPlayer,
            uint256 targetReward
        ) = _splitAndRemoveSettlement();

        _creditReward(hitPlayer, hitReward);
        _creditReward(targetPlayer, targetReward);

        _unlock(true);
        emit SettlementFinalized(
            hitTicketId,
            hitPlayer,
            targetPlayer,
            hitReward,
            targetReward,
            secondGuessSucceeded,
            true
        );
    }

    /// @dev Splits the locked reward between the hit player and the FIRST被命中 player,
    /// then removes the settled tickets and reduces supply. Does not move tokens or unlock.
    /// A self-hit (hit player owns the target ticket) keeps the whole reward.
    function _splitAndRemoveSettlement()
        internal
        returns (
            address hitPlayer,
            uint256 hitReward,
            address targetPlayer,
            uint256 targetReward
        )
    {
        hitPlayer = hitLock.hitPlayer;
        Ticket storage targetTicket = tickets[hitLock.targetTicketId];
        targetPlayer = targetTicket.player;
        uint256 reward = hitLock.rewardAmount;

        if (targetPlayer == hitPlayer) {
            hitReward = reward;
            targetReward = 0;
        } else {
            hitReward = reward / 2;
            targetReward = reward - hitReward;
        }

        if (hitLock.secondGuessSucceeded) {
            _removeAllOccupiedTickets();
        } else {
            uint256 hitId = hitLock.hitTicketId;
            uint256 targetId = hitLock.targetTicketId;
            uint256 left = hitId < targetId ? hitId : targetId;
            uint256 right = hitId < targetId ? targetId : hitId;
            (, uint256 removedSlotCount) = _removeTicketRange(left, right);
            totalSupply -= removedSlotCount;
        }
    }

    function _invalidateHitTicket() internal {
        Ticket storage hitTicket = tickets[hitLock.hitTicketId];
        if (hitTicket.status == TicketStatus.Active) {
            hitTicket.status = TicketStatus.Invalid;
            _clearNumberIndex(hitLock.hitTicketId, hitTicket.randomNumber);
            // Record the missed second-guess number so the table can show it on the voided ticket.
            hitTicket.secondGuessNumber = hitLock.secondGuessNumber;
            _burn(hitLock.hitTicketId);
        }
    }

    /// @dev Sums the stake of every carriage whose ticket id falls within [firstId, secondId],
    /// including withdrawn residual ghosts that still sit between the two ends.
    function _getTicketRangeStake(
        uint256 firstId,
        uint256 secondId
    ) internal view returns (uint256 amount) {
        uint256 left = firstId < secondId ? firstId : secondId;
        uint256 right = firstId < secondId ? secondId : firstId;
        uint256 len = activeTicketIds.length;

        for (uint256 i = 0; i < len; i++) {
            uint256 ticketId = activeTicketIds[i];
            if (ticketId >= left && ticketId <= right) {
                amount += tickets[ticketId].stakeAmount;
            }
        }
    }

    function _getOccupiedStakePool() internal view returns (uint256 amount) {
        uint256 len = activeTicketIds.length;
        for (uint256 i = 0; i < len; i++) {
            amount += tickets[activeTicketIds[i]].stakeAmount;
        }
    }

    /// @dev Removes every carriage whose ticket id is within [left, right]. The returned slot
    /// count excludes withdrawn ghosts — they already freed their slot on withdrawal — so the
    /// caller decrements totalSupply only by the live (Active/Invalid) carriages removed.
    function _removeTicketRange(
        uint256 left,
        uint256 right
    ) internal returns (uint256 removedAmount, uint256 removedSlotCount) {
        uint256 writeIndex;
        uint256 len = activeTicketIds.length;

        for (uint256 readIndex = 0; readIndex < len; readIndex++) {
            uint256 ticketId = activeTicketIds[readIndex];
            Ticket storage t = tickets[ticketId];
            bool inRange = ticketId >= left && ticketId <= right;

            if (
                inRange &&
                (t.status == TicketStatus.Active ||
                    t.status == TicketStatus.Withdrawn ||
                    t.status == TicketStatus.Invalid)
            ) {
                removedAmount += t.stakeAmount;
                if (t.status != TicketStatus.Withdrawn) removedSlotCount += 1;
                _clearNumberIndex(ticketId, t.randomNumber);
                t.stakeAmount = 0;
                t.status = TicketStatus.Removed;
                _burn(ticketId);
            } else {
                activeTicketIds[writeIndex] = ticketId;
                writeIndex += 1;
            }
        }

        while (activeTicketIds.length > writeIndex) {
            activeTicketIds.pop();
        }
    }

    /// @dev O(1) lookup of the lone Active ticket holding `randomNumber` (0 = none).
    function _findAnyActiveTicketByRandom(
        uint256 randomNumber
    ) internal view returns (uint256) {
        return activeTicketIdByNumber[randomNumber];
    }

    /// @dev Release a number's index slot when its ticket stops being Active (only if it is the
    /// registered holder — the second end of a hit is never registered, so this is a safe no-op there).
    function _clearNumberIndex(uint256 ticketId, uint256 randomNumber) internal {
        if (activeTicketIdByNumber[randomNumber] == ticketId) {
            activeTicketIdByNumber[randomNumber] = 0;
        }
    }

    function _removeAllOccupiedTickets() internal {
        uint256 len = activeTicketIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 ticketId = activeTicketIds[i];
            Ticket storage t = tickets[ticketId];
            if (
                t.status == TicketStatus.Active ||
                t.status == TicketStatus.Withdrawn ||
                t.status == TicketStatus.Invalid
            ) {
                _clearNumberIndex(ticketId, t.randomNumber);
                t.stakeAmount = 0;
                t.status = TicketStatus.Removed;
                _burn(ticketId);
            }
        }
        delete activeTicketIds;
        totalSupply = 0;
    }

    function _mint(address to, uint256 tokenId) internal {
        _ownerOf[tokenId] = to;
        _balanceOf[to] += 1;
        emit Transfer(address(0), to, tokenId);
    }

    function _burn(uint256 tokenId) internal {
        address tokenOwner = _ownerOf[tokenId];
        if (tokenOwner == address(0)) return;

        delete _ownerOf[tokenId];
        _balanceOf[tokenOwner] -= 1;
        emit Transfer(tokenOwner, address(0), tokenId);
    }

    // ------------------------------
    // Token helpers (no external library; tolerate non-standard bool-less ERC20s)
    // ------------------------------

    function _tokenBalance() internal view returns (uint256) {
        (bool success, bytes memory data) = settlementToken.staticcall(
            abi.encodeWithSelector(ERC20_BALANCE_OF_SELECTOR, address(this))
        );
        if (!success || data.length < 32) revert TokenTransferFailed();
        return abi.decode(data, (uint256));
    }

    function _safeTokenTransfer(address to, uint256 amount) internal {
        _safeTransferToken(settlementToken, to, amount);
    }

    function _safeTokenTransferFrom(
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = settlementToken.call(
            abi.encodeWithSelector(
                ERC20_TRANSFER_FROM_SELECTOR,
                from,
                to,
                amount
            )
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TokenTransferFailed();
        }
    }

    function _safeTransferToken(
        address token,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(ERC20_TRANSFER_SELECTOR, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TokenTransferFailed();
        }
    }

    // ------------------------------
    // Owner fund recovery (cannot touch funds owed to players)
    // ------------------------------

    /// @notice Sweep settlement tokens that are NOT owed to anyone — fee-on-transfer dust, accidental
    /// transfers, and forfeited ghost residuals left after the round ends. Only callable once the
    /// round is fully settled (closed, no lock, no pending request), and it never removes the stake
    /// still reclaimable by active holders or the unclaimed pendingRewards.
    function sweepSettlementExcess(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidConfig();
        if (!closed || hitLock.active || pendingRequestId != 0) revert Locked();

        uint256 owed = totalPendingRewards;
        uint256 len = activeTicketIds.length;
        for (uint256 i = 0; i < len; i++) {
            Ticket storage t = tickets[activeTicketIds[i]];
            if (t.status == TicketStatus.Active) owed += t.stakeAmount;
        }

        uint256 balance = _tokenBalance();
        uint256 excess = balance > owed ? balance - owed : 0;
        if (excess == 0) revert NothingToClaim();

        _safeTokenTransfer(to, excess);
        emit TokensSwept(settlementToken, to, excess);
    }

    /// @notice Recover any non-settlement token mistakenly sent to this contract.
    function sweepOtherToken(address token, address to) external onlyOwner nonReentrant {
        if (token == settlementToken) revert InvalidToken();
        if (to == address(0)) revert InvalidConfig();

        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(ERC20_BALANCE_OF_SELECTOR, address(this))
        );
        if (!success || data.length < 32) revert TokenTransferFailed();
        uint256 balance = abi.decode(data, (uint256));
        if (balance == 0) revert NothingToClaim();

        _safeTransferToken(token, to, balance);
        emit TokensSwept(token, to, balance);
    }
}
