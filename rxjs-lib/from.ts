import { from } from "rxjs";

const fromObserverable = from([1, 2, 3]);

fromObserverable.subscribe((v) => {
  console.log(`SubjectA: ${v}`);
});

fromObserverable.subscribe((v) => {
  console.log(`SubjectB: ${v}`);
});

/**
SubjectA: 1
SubjectA: 2
SubjectA: 3
SubjectB: 1
SubjectB: 2
SubjectB: 3
 */
