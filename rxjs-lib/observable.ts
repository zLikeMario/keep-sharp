/**
 * Observable 可观察对象
 * 当订阅这个可观察对象时就可以同步得到流里的值
 */
import { Observable } from "rxjs";

const observable = new Observable((subscriber) => {
  /**
   * 有几个订阅者，这里的流程就会执行几遍
   */
  subscriber.next(1);
  subscriber.next(2);
  setTimeout(() => {
    console.log(`setTimeout`);
    subscriber.next(3);
    subscriber.complete();
    subscriber.next(4);
  }, 1000);
});

console.log(`Subject before`);
const subscription = observable.subscribe((v) => {
  console.log(`【1】${v}`);
});
console.log(`【1】取消了订阅`);
subscription.unsubscribe();

observable.subscribe((v) => {
  console.log(`【2】${v}`);
});
console.log(`Subject after`);

// 打印结果
/**
    Subject before
    【1】1
    【1】2
    【1】取消了订阅
    【2】1
    【2】2
    Subject after
    setTimeout
    setTimeout
    【2】3
 */
// TDLLQarzv9sscwEPoPSqiv8CYrCWi8MZwo