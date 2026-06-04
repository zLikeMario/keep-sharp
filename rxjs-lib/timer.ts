import { sleep } from "./../common/utils";
import { from, map, switchMap, tap, timer } from "rxjs";

timer(0, 1000)
  .pipe(
    map(() => Math.random() * 2000 + 1000),
    tap((interval) => console.log(`interval: ${interval}`)),
    switchMap((interval) => {
      console.log(`switchMap: ${interval}`);
      return from(sleep(interval));
    })
  )
  .subscribe((v) => {
    console.log(v);
  });

  /**
  interval: 1550.8770554667108
  switchMap: 1550.8770554667108
  interval: 2541.7232922265443
  switchMap: 2541.7232922265443
  interval: 2483.936129275383
  switchMap: 2483.936129275383
   */