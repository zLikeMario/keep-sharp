import { sleep } from "./../common/utils";
import { defer, from, Subject, switchMap } from "rxjs";

let count = 1;
const fetchData = async () => {
  const id = count++;
  console.log(`调用了 fetchData ${id}`);
  await sleep(2000);
  return `I am data (${id})`;
};

const subject = new Subject();
subject.pipe(switchMap(() => defer(() => from(fetchData())))).subscribe((v) => {
  console.log(v);
});

subject.next(1);
subject.next(2);
sleep(3000).then(() => {
  subject.next(3);
});

// 打印结果
/**
  调用了 fetchData 1
  调用了 fetchData 2
  I am data (2)
  调用了 fetchData 3
  I am data (3)
 */
