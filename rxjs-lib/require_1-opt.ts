import { ref, shallowReactive, onUnmounted, watchEffect } from "vue";
import { from as fromRef } from "@vueuse/rxjs";
import {
  Observable,
  combineLatest,
  concat,
  defer,
  distinctUntilChanged,
  filter,
  from,
  map,
  of,
  shareReplay,
  switchMap,
  catchError,
} from "rxjs";

/* =========================
 * 基础类型
 * ========================= */

type Data<T> =
  | { loading: true; data?: T; error: null }
  | { loading: false; data: T; error: null }
  | { loading: false; data: null; error: any };

interface Network {
  name: string;
  arch: "evm" | "btc" | "solana" | "sui" | "tron" | "aptos" | "ton" | "cosmos";
  chainId: number;
  icon: string;
  nativeCurrency: { symbol: string; decimals: number; name: string };
  rpcs: string[];
}

/* =========================
 * mock utils
 * ========================= */

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function getSupportedNetworks(feature: string): Promise<Network[]> {
  await sleep(300);
  if (feature === "check-balance") {
    return [
      {
        name: "Ethereum",
        arch: "evm",
        chainId: 1,
        icon: "",
        nativeCurrency: { symbol: "ETH", decimals: 18, name: "Ethereum" },
        rpcs: [],
      },
    ];
  }
  return [];
}

async function getNetworkFromChainId(chainId: number): Promise<Network | undefined> {
  await sleep(300);
  if (chainId === 1) {
    return {
      name: "Ethereum",
      arch: "evm",
      chainId: 1,
      icon: "",
      nativeCurrency: { symbol: "ETH", decimals: 18, name: "Ethereum" },
      rpcs: [],
    };
  }
}

async function getDefaultRpc(chainId: number): Promise<string | undefined> {
  await sleep(300);
  if (chainId === 1) {
    return "https://eth-mainnet.public.blastapi.io";
  }
}

async function getChainIdFromRpc(rpc: string): Promise<number> {
  await sleep(300);
  return 1;
}

/* =========================
 * Rx 工具
 * ========================= */

const withLoadingFlow = <T>(task: () => Promise<T>, initData?: T) =>
  defer(() =>
    concat(
      of({ loading: true, data: initData, error: null } as Data<T>),
      from(task()).pipe(
        map((data) => ({ loading: false, data, error: null }) as Data<T>),
        catchError((error) => of({ loading: false, data: null, error } as Data<T>)),
      ),
    ),
  );

function useObservableData<T>(source$: Observable<Data<T>>) {
  const state = shallowReactive<Data<T>>({
    loading: true,
    data: undefined,
    error: null,
  });

  const sub = source$.subscribe((v) => Object.assign(state, v));
  onUnmounted(() => sub.unsubscribe());

  return state;
}

/* =========================
 * Vue 状态源
 * ========================= */

export function useWalletNetworkFlow() {
  const feature = ref<string>();
  const chainId = ref<number>();
  const rpcInput = ref<string>();

  /* =========================
   * Rx 输入流
   * ========================= */

  const feature$ = fromRef(feature).pipe(
    filter((v): v is string => !!v),
    distinctUntilChanged(),
  );

  const chainId$ = fromRef(chainId).pipe(
    filter((v): v is number => typeof v === "number"),
    distinctUntilChanged(),
  );

  const rpcInput$ = fromRef(rpcInput).pipe(
    filter((v): v is string => !!v),
    distinctUntilChanged(),
  );

  /* =========================
   * 支持的网络
   * ========================= */

  const supportedNetworks$ = feature$.pipe(
    switchMap((f) => withLoadingFlow(() => getSupportedNetworks(f))),
    shareReplay({ bufferSize: 1, refCount: true }),
  );

  /* =========================
   * 当前网络
   * ========================= */

  const network$ = chainId$.pipe(
    switchMap((id) =>
      supportedNetworks$.pipe(
        switchMap((supported) => {
          const local = (supported.data ?? []).find((n) => n.chainId === id);
          return local
            ? of({ loading: false, data: local, error: null } as Data<Network>)
            : withLoadingFlow(() => getNetworkFromChainId(id));
        }),
      ),
    ),
    shareReplay({ bufferSize: 1, refCount: true }),
  );

  /* =========================
   * 默认 RPC
   * ========================= */

  const defaultRpc$ = chainId$.pipe(
    switchMap((id) => withLoadingFlow(() => getDefaultRpc(id))),
    shareReplay({ bufferSize: 1, refCount: true }),
  );

  /* =========================
   * RPC 校验
   * ========================= */

  const rpc$ = combineLatest([rpcInput$, chainId$]).pipe(
    switchMap(([rpc, chainId]) =>
      withLoadingFlow(async () => {
        const rpcChainId = await getChainIdFromRpc(rpc);
        if (rpcChainId !== chainId) {
          throw new Error("RPC chainId mismatch");
        }
        return rpc;
      }, rpc),
    ),
    shareReplay({ bufferSize: 1, refCount: true }),
  );

  /* =========================
   * Vue 消费
   * ========================= */

  const supportedNetworks = useObservableData(supportedNetworks$);
  const network = useObservableData(network$);
  const defaultRpc = useObservableData(defaultRpc$);
  const rpc = useObservableData(rpc$);

  /* =========================
   * 默认 RPC 注入
   * ========================= */

  watchEffect(() => {
    if (!rpcInput.value && defaultRpc.data && !defaultRpc.loading) {
      rpcInput.value = defaultRpc.data;
    }
  });

  /* =========================
   * 初始化
   * ========================= */

  feature.value = "check-balance";
  chainId.value = 1;

  return {
    feature,
    chainId,
    rpcInput,
    supportedNetworks,
    network,
    defaultRpc,
    rpc,
  };
}
