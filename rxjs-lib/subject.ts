/**
 * subject 理解为一个输入数据的入口
 * 只有有数据时，才会推
 */
import { Subject } from "rxjs";

const subject = new Subject();

subject.subscribe({
  next: (v) => console.log("observerA: " + v),
});

subject.next(1);

subject.subscribe((v) => {
  console.log(`observerB: ${v}`);
});

/**
 observerA: 1
 */