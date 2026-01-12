import { ReplaySubject } from "rxjs";

/**
 * 包含缓存值的 subject
 */

const subject = new ReplaySubject(3); // 为新的订阅者缓冲3个值

subject.subscribe({
  next: (v) => console.log("observerA: " + v),
});

subject.next(1);
subject.next(2);
subject.next(3);
subject.next(4);

subject.subscribe({
  next: (v) => console.log("observerB: " + v),
});

subject.next(5);

/**
observerA: 1
observerA: 2
observerA: 3
observerA: 4

observerB: 2
observerB: 3
observerB: 4

observerA: 5
observerB: 5
 */
