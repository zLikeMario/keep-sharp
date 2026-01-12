const a = "The cat sat on the mat";
const b = "The cat sat on a mat";

const c = "function test()";
const d = "function tests()";

const e = "aaaaaaaaaaaababaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaababaaaaaaaaaaaaaaaaaaaaaaaaaa";
const f = "aaaaaaaaaaaabbbaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbaaaaaaaaaaaaaaaaaaaaaaaaaa";

const g = "aaaaaaaaaaaababaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaababaaaaaaaaaaaa";
const h = "aaaaaaaaaaaabbaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbaaaaaaaaaaaa";
import { diff } from "diff-match-patch-es";

interface DiffRange {
  type: "reduce" | "increase" | "modify" | "equal";
  old: string;
  now: string;
  oldStart: number;
  oldEnd: number;
  newStart: number;
  newEnd: number;
}

export function compareString(oldStr: string, newStr: string): DiffRange[] {
  const diffs = diff(oldStr, newStr);

  const result: DiffRange[] = [];

  let oldPos = 0;
  let newPos = 0;

  for (let i = 0; i < diffs.length; i++) {
    const [op, text] = diffs[i]!;
    const len = text.length;

    if (op === 0) {
      result.push({
        type: "equal",
        old: text,
        now: text,
        oldStart: oldPos,
        oldEnd: oldPos + len,
        newStart: newPos,
        newEnd: newPos + len,
      });
      oldPos += len;
      newPos += len;
      continue;
    }

    if (op === -1) {
      const next = diffs[i + 1];
      if (next && next[0] === 1) {
        // reduce + increase → modify
        const newText = next[1];
        result.push({
          type: "modify",
          old: text,
          now: newText,
          oldStart: oldPos,
          oldEnd: oldPos + text.length,
          newStart: newPos,
          newEnd: newPos + newText.length,
        });
        oldPos += text.length;
        newPos += newText.length;
        i++;
      } else {
        result.push({
          type: "reduce",
          old: text,
          now: "",
          oldStart: oldPos,
          oldEnd: oldPos + len,
          newStart: newPos,
          newEnd: newPos,
        });
        oldPos += len;
      }
      continue;
    }

    if (op === 1) {
      result.push({
        type: "increase",
        old: "",
        now: text,
        oldStart: oldPos,
        oldEnd: oldPos,
        newStart: newPos,
        newEnd: newPos + len,
      });
      newPos += len;
    }
  }

  return result;
}

const diffs1 = compareString(a, b);
console.log(diffs1);

diffs1.reduce((arr, item) => {}, [] as string[]);

const diffs2 = compareString(c, d);
console.log(diffs2);

const diffs3 = compareString(e, f);
console.log(diffs3);

const diffs4 = compareString(a, b);
console.log(diffs4);

// TDLLQarzv9sscwEPoPSqiv8CYrCWi8MZwo