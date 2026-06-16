// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}

/// @title Train Fire Game (EVM)
/// @notice A configurable on-chain game that mints ticket NFTs and settles rewards on random hits.
contract TrainGame {
    uint256 private constant BPS = 10_000;
    address public constant DEFAULT_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public owner;
    IERC20 public settlementToken;

    // Game configuration
    uint256 public randomRange; // default: 10000 means [0, 10000]
    uint256 public feeBps; // default: 10 = 0.1%
    uint256 public baseEntryAmount; // default: 1 USDC (6 decimals)
    uint256 public entryIncreaseBpsPerTicket; // phase-1 slow slope (bps per active ticket)
    uint256 public entryBoostBpsPerTicket; // phase-2 boosted slope (bps per active ticket)
    uint256 public entryCurveSpanTickets; // curve span used to derive 1/3 and 1/2 pivots
    uint256 public entryCurveJumpBps; // jump at 1/3 pivot
    uint256 public entryCurveMaxMultiplierBps; // asymptotic max multiplier in bps
    uint256 public entryCurveFlattenFactor; // larger value => flatter tail after 1/2
    uint256 public withdrawStartBps; // withdraw ratio for earliest position
    uint256 public withdrawDecayBpsPerPosition; // decay per position
    uint256 public withdrawMinBps; // floor for withdraw ratio
    uint256 public lockDuration; // default: 5 minutes

    // Accounting
    uint256 public totalPool;
    uint256 public protocolFees;

    // Minimal NFT-like ticket data
    string public name = "Train Game Ticket";
    string public symbol = "TGT";
    uint256 public totalSupply;

    enum TicketStatus {
        None,
        Active,
        Removed
    }

    struct Ticket {
        uint256 id;
        address player;
        uint256 position; // sequence number (starts from 1)
        uint256 randomNumber;
        uint256 stakeAmount; // remaining principal still in pool
        bool principalWithdrawn;
        TicketStatus status;
    }

    struct HitLock {
        bool active;
        uint256 deadline;
        uint256 hitTicketId;
        uint256 targetTicketId;
        address hitPlayer;
        bool secondGuessUsed;
    }

    HitLock public hitLock;

    // NFT ownership (non-transferable ticket NFT)
    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;

    // Ticket storage
    mapping(uint256 => Ticket) public tickets;
    uint256[] public activeTicketIds;
    mapping(uint256 => uint256[]) private randomToTicketIds;

    // Withdraw ledgers
    mapping(address => uint256) public pendingRewards;
    mapping(uint256 => bool) public pendingClaimTicket;

    // Reentrancy guard
    uint256 private _entered;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    event Played(
        address indexed player,
        uint256 indexed ticketId,
        uint256 position,
        uint256 randomNumber,
        uint256 amount,
        uint256 fee
    );

    event HitOccurred(
        uint256 indexed hitTicketId,
        uint256 indexed targetTicketId,
        address indexed hitPlayer,
        address targetPlayer,
        uint256 middleAmount,
        uint256 deadline
    );

    event PrincipalWithdrawn(address indexed player, uint256 indexed ticketId, uint256 amount);
    event RewardClaimed(address indexed player, uint256 amount);
    event LockReleased(uint256 indexed hitTicketId, bool timeoutMarked);
    event SecondGuess(address indexed player, uint256 randomNumber, bool hit, uint256 targetTicketId);
    event ConfigUpdated();
    event EntryCurveUpdated();
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);
    event SettlementTokenUpdated(address indexed token, uint256 baseEntryAmount);

    error NotOwner();
    error Locked();
    error InvalidAmount();
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

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered == 1) revert();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor() {
        owner = msg.sender;
        settlementToken = IERC20(DEFAULT_USDC);

        randomRange = 10_000;
        feeBps = 10;
        baseEntryAmount = 1e6;

        // Entry curve: slow increase -> jump near 1/3 -> flatten near 1/2 and after.
        entryIncreaseBpsPerTicket = 20;
        entryBoostBpsPerTicket = 220;
        entryCurveSpanTickets = 300;
        entryCurveJumpBps = 2500;
        entryCurveMaxMultiplierBps = 80_000;
        entryCurveFlattenFactor = 120;

        // Withdraw ratio curve by position index
        withdrawStartBps = 9000;
        withdrawDecayBpsPerPosition = 10;
        withdrawMinBps = 1000;

        lockDuration = 5 minutes;
    }

    // ------------------------------
    // Owner configuration
    // ------------------------------

    function setSettlementToken(address token, uint256 _baseEntryAmount) external onlyOwner {
        if (token == address(0)) revert InvalidToken();
        if (_baseEntryAmount == 0) revert InvalidConfig();

        settlementToken = IERC20(token);
        baseEntryAmount = _baseEntryAmount;

        emit SettlementTokenUpdated(token, _baseEntryAmount);
    }

    function setConfig(
        uint256 _randomRange,
        uint256 _feeBps,
        uint256 _baseEntryAmount,
        uint256 _entryIncreaseBpsPerTicket,
        uint256 _withdrawStartBps,
        uint256 _withdrawDecayBpsPerPosition,
        uint256 _withdrawMinBps,
        uint256 _lockDuration
    ) external onlyOwner {
        if (_randomRange < 2) revert InvalidConfig();
        if (_feeBps > 500) revert InvalidConfig();
        if (_baseEntryAmount == 0) revert InvalidConfig();
        if (_withdrawStartBps > BPS || _withdrawMinBps > _withdrawStartBps) revert InvalidConfig();
        if (_lockDuration == 0) revert InvalidConfig();

        randomRange = _randomRange;
        feeBps = _feeBps;
        baseEntryAmount = _baseEntryAmount;
        entryIncreaseBpsPerTicket = _entryIncreaseBpsPerTicket;
        withdrawStartBps = _withdrawStartBps;
        withdrawDecayBpsPerPosition = _withdrawDecayBpsPerPosition;
        withdrawMinBps = _withdrawMinBps;
        lockDuration = _lockDuration;

        emit ConfigUpdated();
    }

    function setEntryCurveConfig(
        uint256 _entryIncreaseBpsPerTicket,
        uint256 _entryBoostBpsPerTicket,
        uint256 _entryCurveSpanTickets,
        uint256 _entryCurveJumpBps,
        uint256 _entryCurveMaxMultiplierBps,
        uint256 _entryCurveFlattenFactor
    ) external onlyOwner {
        if (_entryCurveSpanTickets < 6) revert InvalidConfig();
        if (_entryCurveMaxMultiplierBps <= BPS) revert InvalidConfig();
        if (_entryCurveFlattenFactor == 0) revert InvalidConfig();

        entryIncreaseBpsPerTicket = _entryIncreaseBpsPerTicket;
        entryBoostBpsPerTicket = _entryBoostBpsPerTicket;
        entryCurveSpanTickets = _entryCurveSpanTickets;
        entryCurveJumpBps = _entryCurveJumpBps;
        entryCurveMaxMultiplierBps = _entryCurveMaxMultiplierBps;
        entryCurveFlattenFactor = _entryCurveFlattenFactor;

        emit EntryCurveUpdated();
    }

    function withdrawProtocolFees(address to, uint256 amount) external onlyOwner nonReentrant {
        if (amount > protocolFees) revert InvalidAmount();
        protocolFees -= amount;
        _safeTokenTransfer(to, amount);
        emit ProtocolFeesWithdrawn(to, amount);
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
        uint256 activeCount = activeTicketIds.length;

        uint256 pivotOne = entryCurveSpanTickets / 3;
        if (pivotOne == 0) pivotOne = 1;

        uint256 pivotTwo = entryCurveSpanTickets / 2;
        if (pivotTwo <= pivotOne) pivotTwo = pivotOne + 1;

        uint256 multiplierBps;
        if (activeCount <= pivotOne) {
            multiplierBps = BPS + activeCount * entryIncreaseBpsPerTicket;
        } else if (activeCount <= pivotTwo) {
            uint256 atPivotOne = BPS + pivotOne * entryIncreaseBpsPerTicket;
            uint256 phaseTwoCount = activeCount - pivotOne;
            multiplierBps = atPivotOne + entryCurveJumpBps + phaseTwoCount * entryBoostBpsPerTicket;
        } else {
            uint256 atPivotOne = BPS + pivotOne * entryIncreaseBpsPerTicket;
            uint256 atPivotTwo =
                atPivotOne +
                entryCurveJumpBps +
                (pivotTwo - pivotOne) * entryBoostBpsPerTicket;

            if (entryCurveMaxMultiplierBps <= atPivotTwo) {
                multiplierBps = atPivotTwo;
            } else {
                uint256 x = activeCount - pivotTwo;
                uint256 tailRange = entryCurveMaxMultiplierBps - atPivotTwo;
                uint256 tailGain = (tailRange * x) / (x + entryCurveFlattenFactor);
                multiplierBps = atPivotTwo + tailGain;
            }
        }

        return (baseEntryAmount * multiplierBps) / BPS;
    }

    function getWithdrawRatioBps(uint256 position) public view returns (uint256) {
        if (position == 0) return withdrawMinBps;
        uint256 decay = (position - 1) * withdrawDecayBpsPerPosition;
        if (decay >= withdrawStartBps) return withdrawMinBps;

        uint256 ratio = withdrawStartBps - decay;
        if (ratio < withdrawMinBps) return withdrawMinBps;
        return ratio;
    }

    // ------------------------------
    // Game flow
    // ------------------------------

    function play() external nonReentrant {
        _autoReleaseLockIfExpired();
        if (hitLock.active) revert Locked();

        uint256 requiredAmount = getCurrentEntryAmount();

        uint256 ticketId = ++totalSupply;
        uint256 position = ticketId;
        uint256 randomNumber = _generateRandom(msg.sender, ticketId) % randomRange;

        _safeTokenTransferFrom(msg.sender, address(this), requiredAmount);

        uint256 fee = (requiredAmount * feeBps) / BPS;
        uint256 net = requiredAmount - fee;

        protocolFees += fee;
        totalPool += net;

        Ticket storage t = tickets[ticketId];
        t.id = ticketId;
        t.player = msg.sender;
        t.position = position;
        t.randomNumber = randomNumber;
        t.stakeAmount = net;
        t.principalWithdrawn = false;
        t.status = TicketStatus.Active;

        _mint(msg.sender, ticketId);
        activeTicketIds.push(ticketId);
        randomToTicketIds[randomNumber].push(ticketId);

        emit Played(msg.sender, ticketId, position, randomNumber, requiredAmount, fee);

        uint256 targetTicketId = _findAnotherActiveTicketByRandom(randomNumber, ticketId);
        if (targetTicketId != 0) {
            _handleHit(ticketId, targetTicketId);
        }
    }

    function withdrawPrincipal(uint256 ticketId) external nonReentrant {
        _autoReleaseLockIfExpired();

        Ticket storage t = tickets[ticketId];
        if (t.status != TicketStatus.Active) revert TicketNotActive();
        if (t.player != msg.sender) revert NotTicketOwner();
        if (t.principalWithdrawn) revert AlreadyWithdrawn();

        uint256 ratioBps = getWithdrawRatioBps(t.position);
        uint256 amount = (t.stakeAmount * ratioBps) / BPS;
        if (amount == 0) revert NothingToClaim();

        t.principalWithdrawn = true;
        t.stakeAmount -= amount;
        totalPool -= amount;

        _safeTokenTransfer(msg.sender, amount);
        emit PrincipalWithdrawn(msg.sender, ticketId, amount);
    }

    function claimReward() external nonReentrant {
        _autoReleaseLockIfExpired();
        uint256 amount = pendingRewards[msg.sender];
        if (amount == 0) revert NothingToClaim();

        pendingRewards[msg.sender] = 0;
        totalPool -= amount;

        _safeTokenTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    /// @notice During lock window, hit player can choose immediate extraction and unlock game.
    function hitPlayerClaimAndUnlock() external nonReentrant {
        if (!hitLock.active) revert LockNotActive();
        if (msg.sender != hitLock.hitPlayer) revert NotHitPlayer();

        uint256 amount = pendingRewards[msg.sender];
        if (amount == 0) revert NothingToClaim();

        pendingRewards[msg.sender] = 0;
        totalPool -= amount;
        _safeTokenTransfer(msg.sender, amount);

        _unlock(false);
        emit RewardClaimed(msg.sender, amount);
    }

    /// @notice Hit player can perform one second guess during lock.
    /// If hit succeeds, all current active stakes are split 50/50 between hit player and target player.
    function secondGuess() external nonReentrant {
        if (!hitLock.active) revert LockNotActive();
        if (msg.sender != hitLock.hitPlayer) revert NotHitPlayer();
        if (block.timestamp > hitLock.deadline) revert LockNotExpired();
        if (hitLock.secondGuessUsed) revert AlreadySecondGuessed();

        hitLock.secondGuessUsed = true;

        uint256 randomNumber = _generateRandom(msg.sender, totalSupply + 1) % randomRange;
        uint256 targetTicketId = _findAnyActiveTicketByRandom(randomNumber);

        bool success = targetTicketId != 0;
        if (success) {
            address targetPlayer = tickets[targetTicketId].player;
            uint256 activeStakePool = _drainAllActiveStakes();

            uint256 half = activeStakePool / 2;
            pendingRewards[msg.sender] += half;
            pendingRewards[targetPlayer] += activeStakePool - half;

            _removeTicket(targetTicketId);
        }

        emit SecondGuess(msg.sender, randomNumber, success, targetTicketId);
        _unlock(false);
    }

    /// @notice Anyone can release lock after timeout; system only marks hit ticket as pending claim and unlocks.
    function releaseLockAfterTimeout() external {
        if (!hitLock.active) revert LockNotActive();
        if (block.timestamp < hitLock.deadline) revert LockNotExpired();
        _unlock(true);
    }

    // ------------------------------
    // Internal settlement
    // ------------------------------

    function _handleHit(uint256 hitTicketId, uint256 targetTicketId) internal {
        Ticket storage hitT = tickets[hitTicketId];
        Ticket storage targetT = tickets[targetTicketId];

        uint256 left = hitT.position < targetT.position ? hitT.position : targetT.position;
        uint256 right = hitT.position < targetT.position ? targetT.position : hitT.position;

        uint256 middleAmount;
        for (uint256 i = 0; i < activeTicketIds.length; i++) {
            Ticket storage t = tickets[activeTicketIds[i]];
            if (t.status == TicketStatus.Active && t.position >= left && t.position <= right) {
                middleAmount += t.stakeAmount;
                t.stakeAmount = 0;
            }
        }

        uint256 half = middleAmount / 2;
        pendingRewards[hitT.player] += half;
        pendingRewards[targetT.player] += middleAmount - half;

        _removeTicket(hitTicketId);
        _removeTicket(targetTicketId);

        hitLock = HitLock({
            active: true,
            deadline: block.timestamp + lockDuration,
            hitTicketId: hitTicketId,
            targetTicketId: targetTicketId,
            hitPlayer: hitT.player,
            secondGuessUsed: false
        });

        emit HitOccurred(hitTicketId, targetTicketId, hitT.player, targetT.player, middleAmount, hitLock.deadline);
    }

    function _unlock(bool timeoutMarked) internal {
        uint256 hitTicketId = hitLock.hitTicketId;
        if (timeoutMarked) {
            pendingClaimTicket[hitTicketId] = true;
        }
        delete hitLock;
        emit LockReleased(hitTicketId, timeoutMarked);
    }

    function _autoReleaseLockIfExpired() internal {
        if (hitLock.active && block.timestamp >= hitLock.deadline) {
            _unlock(true);
        }
    }

    function _removeTicket(uint256 ticketId) internal {
        Ticket storage t = tickets[ticketId];
        if (t.status != TicketStatus.Active) return;
        t.status = TicketStatus.Removed;
        t.stakeAmount = 0;

        // Remove from activeTicketIds (swap & pop)
        uint256 len = activeTicketIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (activeTicketIds[i] == ticketId) {
                if (i != len - 1) {
                    activeTicketIds[i] = activeTicketIds[len - 1];
                }
                activeTicketIds.pop();
                break;
            }
        }
    }

    function _findAnotherActiveTicketByRandom(
        uint256 randomNumber,
        uint256 selfTicketId
    ) internal view returns (uint256) {
        uint256[] storage list = randomToTicketIds[randomNumber];
        for (uint256 i = 0; i < list.length; i++) {
            uint256 candidateId = list[i];
            if (candidateId != selfTicketId && tickets[candidateId].status == TicketStatus.Active) {
                return candidateId;
            }
        }
        return 0;
    }

    function _findAnyActiveTicketByRandom(uint256 randomNumber) internal view returns (uint256) {
        uint256[] storage list = randomToTicketIds[randomNumber];
        for (uint256 i = 0; i < list.length; i++) {
            uint256 candidateId = list[i];
            if (tickets[candidateId].status == TicketStatus.Active) {
                return candidateId;
            }
        }
        return 0;
    }

    function _drainAllActiveStakes() internal returns (uint256 activeStakePool) {
        uint256 len = activeTicketIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 ticketId = activeTicketIds[i];
            Ticket storage t = tickets[ticketId];
            if (t.status == TicketStatus.Active) {
                activeStakePool += t.stakeAmount;
                t.stakeAmount = 0;
                t.status = TicketStatus.Removed;
            }
        }
        delete activeTicketIds;
    }

    function _mint(address to, uint256 tokenId) internal {
        _ownerOf[tokenId] = to;
        _balanceOf[to] += 1;
        emit Transfer(address(0), to, tokenId);
    }

    function _generateRandom(address player, uint256 nonce) internal view returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        block.prevrandao,
                        blockhash(block.number - 1),
                        block.timestamp,
                        player,
                        nonce,
                        totalSupply,
                        activeTicketIds.length
                    )
                )
            );
    }

    function _safeTokenTransfer(address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(settlementToken).call(
            abi.encodeCall(IERC20.transfer, (to, amount))
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TokenTransferFailed();
        }
    }

    function _safeTokenTransferFrom(address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(settlementToken).call(
            abi.encodeCall(IERC20.transferFrom, (from, to, amount))
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TokenTransferFailed();
        }
    }
}
