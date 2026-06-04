/**
 * -. 下拉记载更多的列表数据
 */

import { from, fromEvent, useObservable } from "@vueuse/rxjs";
import { forkJoin, of } from "rxjs";
import { ajax } from "rxjs/ajax";
import { concatAll, map, mergeMap, pluck, scan, take } from "rxjs/operators";
import { useTemplateRef } from "vue";

const BASE_URL = "https://jsonplaceholder.typicode.com";
const button = useTemplateRef<HTMLElement>("buttonRef");

const posts = useObservable(
  fromEvent(button, "click").pipe(
    mergeMap(() =>
      ajax.getJSON<{ id: string; userId: string; title: string }[]>(`${BASE_URL}/posts`).pipe(
        concatAll(),
        take(4),
        mergeMap(
          ({ id, userId, title }) =>
            forkJoin({
              id: of(id),
              comments: ajax
                .getJSON<string[]>(`${BASE_URL}/posts/${id}/comments`)
                .pipe(map((comments) => comments.length)),
              username: ajax.getJSON<{ username: string }>(`${BASE_URL}/users/${userId}`).pipe(pluck("username")),
            }),
          2,
        ),
        scan((acc, curr) => [...acc, curr], []),
      ),
    ),
  ),
);
