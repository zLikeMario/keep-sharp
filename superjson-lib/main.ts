import { stringify, registerCustom, allowErrorProps } from "superjson";

function safeHas(key: string, target: any) {
  if (target === null) return false;
  const t = typeof target;
  if (t !== "object" && t !== "function") return false;
  return key in target;
}

registerCustom(
  {
    isApplicable: (i: any): i is any => safeHas("constructor", i) || safeHas("prototype", i) || safeHas("__proto__", i),
    serialize: (i: any) => {
      const { constructor: _, prototype: __, __proto__: ___, ...other } = i;
      return { ...other };
    },
    deserialize: (o: any) => ({ ...o, stack: "" }),
  },
  "stack"
);

const blob = new Blob();
const data: any = {
  arr: [[1, 23], [[{ name: "asdf" }]]],
  undef: undefined,
  n: null,
  stack: "stttttt",
  name: "zym",
  age: 20,
  s: 1n,
  h: class {
    static x = 1;
  },
  func: function () {},
  failed: new Error("我是错误信息"),
  fiel: new File([blob], "1.js"),
  constructor: () => {},
  prototype: "prototype",
  inset: {
    data: {
      file: new File([new Blob(["1"])], "insert.ts"),
    },
  },
};
data.data = data;

const result = stringify(data);
console.log(result);
