/**
 * 和 subject 一样，但是他有当前值的推送
 */
import { BehaviorSubject, map, tap } from "rxjs";

const behaviorSubject = new BehaviorSubject(0);

behaviorSubject.subscribe({
  next: (v) => console.log("observerA: " + v),
});

behaviorSubject.subscribe((v) => {
  console.log(`observerB: ${v}`);
});

/**
  observerA: 0
  observerB: 0
 */

const newBehaviorSubject = behaviorSubject.pipe(
  tap(() => console.log(1)),
  map((v) => v + 1)
);

newBehaviorSubject.subscribe({
  next: (v) => console.log("observerA: " + v),
});

newBehaviorSubject.subscribe((v) => {
  console.log(`observerB: ${v}`);
});

/**
  1
  observerA: 1
  1
  observerB: 1
 */
