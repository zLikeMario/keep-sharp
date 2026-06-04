import { catchError, defer, EMPTY, expand, of, retry, switchMap, takeWhile, tap, timeout, timer } from "rxjs";
import { sleep } from "../common/utils";

async function getOrderStatus() {
  const sleepTime = Math.random() * 5000;
  const num = Math.random();
  if (sleepTime > 2000) {
    console.log(`⏰ 超时重试，将会在 2s 后重试 (${sleepTime})`);
  } else {
    if (num < 0.05) {
      console.log(`❌ 获取订单数据失败，将会在 2s 后重试 (${sleepTime})`);
    } else if (num < 0.8) {
      console.log(`⌚️ 订单正在等待支付中..., 准备 2s后 重新 check 订单状态 (${sleepTime})`);
    } else {
      console.log(`✅ 订单已支付完成. (${sleepTime})`);
    }
  }
  await sleep(sleepTime);
  if (num < 0.05) throw "Order Error";
  return { status: num < 0.8 ? "pending" : "success" };
}

const checkOrderStatusFlow = () =>
  defer(() => getOrderStatus()).pipe(
    tap(() => console.log("🦅 Call Function")),
    timeout({
      each: 2000,
      with: () => {
        console.log("⏰ RxJS timeout");
        throw new Error("timeout");
      },
    }),
    retry({ count: 3, delay: 2000 }),
    catchError((err) => {
      console.log(`接收到错误: ${err}`);
      return of({ status: "failed" });
    }),
  );

checkOrderStatusFlow()
  .pipe(
    tap(() => console.log("🦅 Call Function2")),
    expand((order) => {
      if (order.status === "pending") {
        return timer(2000).pipe(switchMap(() => checkOrderStatusFlow()));
      }
      return EMPTY;
    }),
    takeWhile((order) => {
      console.log(`[TakeWhile] Status: ${order.status}`);
      return order.status === "pending";
    }, true),
    tap((order) => {
      console.log(`[TAP] Status: ${order.status}`);
    }),
  )
  .subscribe({
    next: () => {
      console.log("Next");
    },
    complete: () => {
      console.log("Complete");
    },
  });
