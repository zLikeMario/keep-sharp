import { BehaviorSubject, map, of, Subject, switchMap, tap } from "rxjs";

const subject1 = new BehaviorSubject<{ t: string; v: number }>({ t: "Subject1", v: 555 });

const subject2 = new Subject<{ t: string; v: number }>();
subject2
  .pipe(
    tap(() => console.log("tap")),
    switchMap((r) => {
      if (!r.v) return of(r);
      // 多次订阅之前的流会自动处理掉
      return subject1.pipe(map((r) => r));
    })
  )
  .subscribe((r) => {
    console.log(`${r.t} 结果 ${r.v}`);
  });

subject2.next({ v: 0, t: "Subject2" });
subject2.next({ v: 1, t: "Subject2" });

subject1.next({ v: 666, t: "Subject1" });
subject1.next({ v: 999, t: "Subject1" });

subject2.next({ v: 0, t: "Subject2" });
subject2.next({ v: 1, t: "Subject2" });
subject1.next({ v: 222, t: "Subject1" });

// 打印结果
/**
  tap
  Subject2 结果 0
  tap
  Subject1 结果 555

  Subject1 结果 666
  Subject1 结果 999
  
  tap
  Subject2 结果 0
  tap
  Subject1 结果 999
  Subject1 结果 222
 */
