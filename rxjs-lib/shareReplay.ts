import { tap, interval, take, shareReplay } from "rxjs";

//  * 再次执行的 subject 不会重新走 pipe 流程

const flow = interval(1000).pipe(take(5));
flow.subscribe((v) => console.log(`flow AAAAA: ${v}`));
setTimeout(() => {
  flow.subscribe((v) => console.log(`flow BBBBB: ${v}`));
}, 5500);

const shared0 = interval(1000).pipe(take(5), shareReplay(5));
shared0.subscribe((v) => console.log(`shared0 AAAAA: ${v}`));
setTimeout(() => {
  shared0.subscribe((v) => console.log(`shared0 BBBBB: ${v}`));
}, 5500);

const shared1 = interval(2000).pipe(
  tap((v) => console.log(`shared1-tap: ${v}`)),
  shareReplay(3),
);

shared1.pipe(take(2)).subscribe((v) => console.log(`shared1 AAAAA: ${v}`));

const shared2 = interval(2000).pipe(
  tap((v) => console.log(`shared2-tap: ${v}`)),
  shareReplay({ refCount: true, bufferSize: 3 }),
);
shared2.pipe(take(2)).subscribe((v) => console.log(`shared2 AAAAA: ${v}`));

const shared3 = interval(2000).pipe(
  take(2), // 除非主动让他停止
  tap((v) => console.log(`shared3-tap: ${v}`)),
  shareReplay(3),
);
shared3.subscribe((v) => console.log(`shared3 AAAAA: ${v}`));

// /**
//  * 如果 shareReplay 直接传一个数字，那么 refCount 就是 false, 这个流不会自动停止，除非主动让他停止
//  */
