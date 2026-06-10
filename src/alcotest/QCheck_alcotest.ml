
module Q = QCheck2
module T = QCheck2.Test
module Raw = QCheck_base_runner.Raw

let seed_ = lazy (
  let s =
    try int_of_string @@ Sys.getenv "QCHECK_SEED"
    with _ ->
      Random.self_init();
      Random.int 1_000_000_000
  in
  Printf.printf "qcheck random seed: %d\n%!" s;
  s
)

let default_rand () =
  (* random seed, for repeatability of tests *)
  Random.State.make [| Lazy.force seed_  |]

let verbose_ = lazy (
  match Sys.getenv "QCHECK_VERBOSE" with
  | "1" | "true" -> true
  | _ -> false
  | exception Not_found -> false
)

let long_ = lazy (
  match Sys.getenv "QCHECK_LONG" with
  | "1" | "true" -> true
  | _ -> false
  | exception Not_found -> false
)

let to_alcotest
    ?(colors=false) ?(verbose=Lazy.force verbose_) ?(long=Lazy.force long_)
    ?(debug_shrink = None) ?debug_shrink_list ?(speed_level = `Slow)
    ?(rand=default_rand()) (t:T.t) =
  let T.Test cell = t in
  let handler name cell r =
    match r, debug_shrink with
    | QCheck2.Test.Shrunk (step, x), Some out ->
      let go = match debug_shrink_list with
        | None -> true
        | Some test_list -> List.mem name test_list in
      if not go then ()
      else
        QCheck_base_runner.debug_shrinking_choices
          ~colors ~out ~name cell ~step x
    | _ ->
      ()
  in
  let print = Raw.print_std in
  let name = T.get_name cell in
  let run () =
    let call = Raw.callback ~colors ~verbose ~print_res:false ~print in
    let res = T.check_cell ~long ~call ~handler ~rand cell in
    let count = Q.TestResult.get_count res in
    let incomplete = Q.TestResult.get_count_incomplete res in
    let failed =
      match Q.TestResult.get_state res with
      | Q.TestResult.Success -> 0
      | Q.TestResult.Failed { instances } -> List.length instances
      | Q.TestResult.Failed_other _ -> 0
      | Q.TestResult.Error _ -> 1
    in
    let passed = count - failed in
    let format_reasons indent =
      Q.TestResult.get_todo_reasons res
      |> List.map (fun (r, c) -> Printf.sprintf "\n%s%s (%d times)" indent r c)
      |> String.concat ""
    in
    let stats_line =
      if incomplete > 0
      then Printf.sprintf "\n(passed: %d, incomplete: %d, failed: %d)%s"
             passed incomplete failed (format_reasons "  ")
      else ""
    in
    if incomplete > 0 then begin
        (* Only rewrap the exception when we actually have incremental stats to
           append; otherwise let the original QCheck exception propagate exactly
           as upstream does (keeps the change additive). *)
        (try T.check_result cell res
         with exn ->
           let bt = Printexc.get_raw_backtrace () in
           let msg = Printexc.to_string exn ^ stats_line in
           Printexc.raise_with_backtrace (Failure msg) bt);
        failwith
          (Printf.sprintf "TODO:\n(passed: %d, incomplete: %d, failed: %d)%s"
             passed incomplete failed (format_reasons "  "))
      end else
      T.check_result cell res
  in
  ((name, speed_level, run) : unit Alcotest.test_case)
