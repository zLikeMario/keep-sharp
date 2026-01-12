/**
 * 合并多个流，按顺序发
 */
import { concat, interval, map, take, timer } from "rxjs";

const timer1 = interval(1000).pipe(
  take(3),
  map((v) => `timer1: ${v}`)
);
const timer2 = interval(1000).pipe(
  take(3),
  map((v) => `timer2: ${v}`)
);
const timer3 = interval(500).pipe(
  take(3),
  map((v) => `timer3: ${v}`)
);

concat(timer1, timer2, timer3, timer1).subscribe((v) => {
  console.log(v);
});

/**
  timer1: 0
  timer1: 1
  timer1: 2

  timer2: 0
  timer2: 1
  timer2: 2

  timer3: 0
  timer3: 1
  timer3: 2
  
  timer1: 0
  timer1: 1
  timer1: 2
 */
