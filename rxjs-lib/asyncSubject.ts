import { AsyncSubject } from "rxjs";

const asyncSubject = new AsyncSubject();

asyncSubject.subscribe((v) => {
  console.log(`Sub1: ${v}`);
});

asyncSubject.next(1);
asyncSubject.next(2);
asyncSubject.complete();

asyncSubject.subscribe((v) => {
  console.log(`Sub2: ${v}`);
});

/**
  Sub1: 2
  Sub2: 2
 */
