/**
 * * 通过 rxjs 处理所有状态，将状态包在流中，当使用的时候通过订阅去获取，并需要节省流量，共用相通的流
 *
 * -. 根据 feature, 获取到当前功能支持的网络
 * -. network, 检测是否是合法的 network
 * -. 根据 network 获取 native 代币信息
 * -. rpc, 根据 network 判断是否是合法的 rpc
 * -. 根据 network 获取默认 rpc
 * -. 根据 rpc 获取 native 代币余额
 * -. tokenAddress,  根据 rpc 判断是否是正确的 tokenAddress
 * -. 根据 network 获取曾经操作过的代币数据
 * -. 根据 tokenAddress, 拿到代币余额
 * -. 根据 tokenAddress, 拿到代币数据（name, symbol, decimals, isNative）
 * -. 根据 network 和 rpc 可获取 gasPrice，以及是否支持 eip1559
 */
import { isUndefined } from "@zlikemario/helper/utils";
import { sleep } from "./../common/utils";
import {
  BehaviorSubject,
  catchError,
  combineLatest,
  concat,
  defer,
  delay,
  distinctUntilChanged,
  filter,
  from,
  map,
  of,
  shareReplay,
  Subject,
  switchMap,
} from "rxjs";
import { computed, ref, shallowReactive, shallowRef, watch, watchEffect } from "vue";

type MaybeNull<T> = T | null;
type Possibility<T> = T | null | undefined;

type Data<T> =
  | { loading: boolean; data?: T; error: null }
  | { loading: boolean; data: T; error: null }
  | { loading: boolean; data: null; error: any };

interface Network {
  name: string;
  arch: "evm" | "btc" | "solana" | "sui" | "tron" | "aptos" | "ton" | "cosmos";
  chainId: number;
  icon: string;
  nativeCurrency: { symbol: string; decimals: number; name: string };
  rpcs: Array<string>;
}

async function getSupportedNetworks(feature: string): Promise<Network[]> {
  await sleep(Math.random() * 1500);
  switch (feature) {
    case "check-balance":
      return Promise.resolve([
        {
          name: "Ethereum",
          arch: "evm",
          chainId: 1,
          icon: "",
          nativeCurrency: { symbol: "ETH", decimals: 18, name: "Ethereum" },
          rpcs: [""],
        },
      ]);
  }
  return Promise.resolve([]);
}

async function getNetworkFromChainId(chianId: number): Promise<Network | undefined> {
  await sleep(Math.random() * 1500);
  if (chianId === 1) {
    return {
      name: "Ethereum",
      arch: "evm",
      chainId: 1,
      icon: "",
      nativeCurrency: { symbol: "ETH", decimals: 18, name: "Ethereum" },
      rpcs: [""],
    };
  }
  return void 0;
}

async function getDefaultRpc(chianId: number): Promise<string | undefined> {
  await sleep(Math.random() * 1500);
  if (chianId === 1) {
    return "https://eth-mainnet.public.blastapi.io";
  }
  return void 0;
}

async function getChainIdFromRpc(rpc: string): Promise<number | undefined> {
  await sleep(Math.random() * 1500);
  const response = await fetch(rpc, { method: "post", body: JSON.stringify({ method: "eth_chainId", params: [] }) });
  const result = await response.json();
  return result;
}

const withLoadingFlow = <T>(task: () => Promise<T>, options?: Partial<{ initData?: T }>) => {
  return defer(() =>
    concat(
      of({ loading: true, data: options?.initData, error: null }),
      from(task()).pipe(
        map((value) => ({ loading: false, data: value, error: null })),
        catchError((error) => of({ loading: false, data: null, error })),
      ),
    ),
  );
};

const computeWithData = <R, T>(v: Data<T>, compute: (v: Exclude<T, null | undefined>) => R) => {
  if (v.data === null || v.data === undefined) return v.data as null | undefined;
  return compute(v.data as Exclude<T, null | undefined>);
};

// feature 用来获取支持了哪些网络
const feature$ = new Subject<Possibility<string>>();
const supportedNetworks$ = feature$.pipe(
  filter((feature): feature is string => !!feature),
  distinctUntilChanged(),
  switchMap((feature) => withLoadingFlow(() => getSupportedNetworks(feature))),
  shareReplay({ refCount: true, bufferSize: 1 }),
);

// chainId 用来获取网络信息
const chainId$ = new Subject<Possibility<number>>();
const network$ = chainId$.pipe(
  filter((chainId): chainId is number => !isUndefined(chainId)),
  distinctUntilChanged(),
  switchMap((chainId) =>
    supportedNetworks$.pipe(
      switchMap((supportedNetworks) => {
        const network = computeWithData(supportedNetworks, (networks) =>
          networks.find((network) => network.chainId === chainId),
        );
        return withLoadingFlow(() => (network ? Promise.resolve(network) : getNetworkFromChainId(chainId)));
      }),
    ),
  ),
  shareReplay({ refCount: true, bufferSize: 1 }),
);

// rpc
const defaultRpc$ = chainId$.pipe(
  filter((chainId): chainId is number => !isUndefined(chainId)),
  distinctUntilChanged(),
  switchMap((chainId) => withLoadingFlow(() => getDefaultRpc(chainId))),
  shareReplay({ refCount: true, bufferSize: 1 }),
);
const rpc$ = new Subject<Possibility<string>>();
const rpcVerify$ = rpc$.pipe(
  distinctUntilChanged(),
  switchMap((rpc) => {
    if (!rpc) return of({ loading: false, error: new Error("RPC is required"), data: "" });
    return chainId$.pipe(
      switchMap((_chainId) =>
        withLoadingFlow(
          async () => {
            const chainId = await getChainIdFromRpc(rpc);
            const isValid = chainId === _chainId;
            if (!isValid) throw new Error(`Invalid rpc: ${rpc}`);
            return rpc;
          },
          { initData: rpc },
        ),
      ),
    );
  }),
  shareReplay({ refCount: true, bufferSize: 1 }),
);

// 1. 进 检查余额的 页面
feature$.next("check-balance");

// 2. 展示默认优先显示的网络
const supportedNetworks = shallowReactive<Data<Network[]>>({ data: void 0, loading: true, error: null });
supportedNetworks$.subscribe((networks) => {
  supportedNetworks.data = networks.data;
  supportedNetworks.loading = networks.loading;
  supportedNetworks.error = networks.error;
});

// 3. 展示当前钱包选中的网络，假如是 chainId: 1
const walletChainId = ref(1);
watchEffect(() => chainId$.next(walletChainId.value));
const walletNetwork = shallowReactive<Data<Network>>({ data: void 0, loading: true, error: null });
network$.subscribe((network) => {
  walletNetwork.data = network.data;
  walletNetwork.loading = network.loading;
  walletNetwork.error = network.error;
});

// 4. 展示 rpc，可用的 rpc
const defaultRpc = shallowReactive<Data<string>>({ data: void 0, loading: true, error: null });
const rpc = shallowReactive<Data<string>>({ data: void 0, loading: true, error: null });
watchEffect(() => rpc$.next(rpc.data));
defaultRpc$.subscribe((_defaultRpc) => {
  defaultRpc.data = _defaultRpc.data;
  defaultRpc.error = _defaultRpc.error;
  defaultRpc.loading = _defaultRpc.loading;
});
rpcVerify$.subscribe((rpcResult) => {
  rpc.data = rpcResult.data;
  rpc.error = rpcResult.error;
  rpc.loading = rpcResult.loading;
});
watch(defaultRpc, (defaultRpcResult) => {
  if (!defaultRpcResult.error && defaultRpcResult.data && !defaultRpcResult.loading) {
    if (!rpc.data) {
      rpc.error = null;
      rpc.loading = false;
      rpc.data = defaultRpcResult.data;
    }
  }
});
