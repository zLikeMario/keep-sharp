type RandomHitResult = {
  rangeSize: number;
  duplicateAt: number | null;
  doubleDuplicateAt: number | null;
  totalDraws: number;
};

/**
 * 模拟从 0 ~ rangeSize - 1 中不断随机取数字
 *
 * @param rangeSize 数字总数量，例如 1000000 表示 0 ~ 999999
 * @param maxDraws 最大随机次数，防止死循环
 */
function testRandomHits(rangeSize: number, maxDraws: number = 10_000): RandomHitResult {
  const appeared = new Set<number>();

  let duplicateAt: number | null = null;
  let doubleDuplicateAt: number | null = null;

  // 上一次是否命中了前面出现过的数字
  let lastWasDuplicate = false;

  for (let drawCount = 1; drawCount <= maxDraws; drawCount++) {
    const num = Math.floor(Math.random() * rangeSize);

    const isDuplicate = appeared.has(num);

    if (isDuplicate && duplicateAt === null) {
      duplicateAt = drawCount;
    }

    if (isDuplicate && lastWasDuplicate) {
      doubleDuplicateAt = drawCount;

      return {
        rangeSize,
        duplicateAt,
        doubleDuplicateAt,
        totalDraws: drawCount,
      };
    }

    appeared.add(num);
    lastWasDuplicate = isDuplicate;
  }

  return {
    rangeSize,
    duplicateAt,
    doubleDuplicateAt,
    totalDraws: maxDraws,
  };
}

function runManyTimes(times: number, rangeSize: number) {
  let duplicateTotal = 0;
  let doubleDuplicateTotal = 0;

  let duplicateCount = 0;
  let doubleDuplicateCount = 0;

  for (let i = 0; i < times; i++) {
    const result = testRandomHits(rangeSize);

    if (result.duplicateAt !== null) {
      duplicateTotal += result.duplicateAt;
      duplicateCount++;
    }

    if (result.doubleDuplicateAt !== null) {
      doubleDuplicateTotal += result.doubleDuplicateAt;
      doubleDuplicateCount++;
    }
  }

  return {
    times,
    rangeSize,

    averageDuplicateAt: duplicateTotal / duplicateCount,
    averageDoubleDuplicateAt: doubleDuplicateTotal / doubleDuplicateCount,
  };
}

console.log(runManyTimes(100, 10000));
