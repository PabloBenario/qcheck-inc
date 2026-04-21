module G = QCheck2.Gen

(* ========================================================================= *)
(* SECTION 1: SYNTAX & FORMATTING                                            *)
(* ========================================================================= *)

type term =
  | Var of int
  | Abs of int * term
  | App of term * term
  | Con of int


let rec pp_term fmt = function
  | Var x -> Format.fprintf fmt "v%d" x
  | Abs (x, t) -> Format.fprintf fmt "(λv%d.%a)" x pp_term t
  | App (t1, t2) -> Format.fprintf fmt "(%a %a)" pp_term t1 pp_term t2
  | Con c -> Format.fprintf fmt "%d" c

let print_term t = Format.asprintf "%a" pp_term t

(* ========================================================================= *)
(* SECTION 2: LOGIC & HELPERS                                                *)
(* ========================================================================= *)

(* --- Free Vars & Max ID --- *)

let rec free_vars t =
  match t with
  | Var x -> [x]
  | Con _ -> []
  | App (t1, t2) -> (free_vars t1) @ (free_vars t2)
  | Abs (x, body) ->
      List.filter (fun v -> v <> x) (free_vars body)

let rec max_id t =
  match t with
  | Var x -> x
  | Con _ -> 0
  | App (t1, t2) -> max (max_id t1) (max_id t2)
  | Abs (x, body) -> max x (max_id body)

(* --- Set Helpers --- *)

let normalize l = List.sort_uniq compare l
let set_equal l1 l2 = compare (normalize l1) (normalize l2) = 0
let set_union l1 l2 = normalize (l1 @ l2)
let set_remove x l = List.filter (fun y -> y <> x) l


(* --- Scoping Logic --- *)

(* This function is only used by the shrinker! *)
let rec subst_dummy target_id term =
  match term with
  | Con c -> Con c
  | Var y -> if target_id = y then Con 0 else Var y
  | App (t1, t2) -> App (subst_dummy target_id t1, subst_dummy target_id t2)
  | Abs (y, body) ->
      if target_id = y then Abs (y, body)
      else Abs (y, subst_dummy target_id body)

let is_well_scoped t =
  let rec check env = function
    | Con _ -> true
    | Var x -> List.mem x env
    | Abs (x, body) -> check (x :: env) body
    | App (t1, t2) -> check env t1 && check env t2
  in
  check [] t

(* ========================================================================= *)
(* SECTION 3: SUBSTITUTION IMPLEMENTATIONS                                   *)
(* ========================================================================= *)

(* 1. NAIVE (Buggy) *)
let rec subst_naive x s t =
  match t with
  | Var y -> if x = y then s else Var y
  | Con c -> Con c
  | App (t1, t2) -> App (subst_naive x s t1, subst_naive x s t2)
  | Abs (y, body) ->
      if x = y then Abs (y, body)
      else Abs (y, subst_naive x s body) (* BUG: Captures y if y in FV(s) *)

(* 2. CORRECT, but incomplete on purpose (Capture-Avoiding) [x:=s]t *)
let rec subst_incom x s t =
  match t with
  | Var y -> if x = y then s else Var y
  | Con c -> Con c
  | App (t1, t2) -> App (subst_incom x s t1, subst_incom x s t2)
  | Abs (y, _) ->
      if x = y then t
      else
        failwith "TODO:subst_incom: Abs case"

(* 3. MIXED: partial implementation with BOTH a real bug AND incomplete branches.
   - Var / Con / App / (x=y) Abs  → handled correctly (passes)
   - Abs (y, Abs _)                → NOT implemented yet, raises failwith "TODO:..."
   - Abs (y, non-Abs body)         → naive recursion, BUG: captures y if y ∈ FV(s) *)
let rec subst_mixed x s t =
  match t with
  | Var y -> if x = y then s else Var y
  | Con c -> Con c
  | App (t1, t2) -> App (subst_mixed x s t1, subst_mixed x s t2)
  | Abs (y, body) ->
      if x = y then t
      else
        (match body with
         | Abs _ -> failwith "TODO:subst_mixed: nested Abs"
         | _     -> Abs (y, subst_mixed x s body))


(* 4. Virtually the same as 3. but we see it throws failwith "TODO:..." in
   two different parts and we will see what happens *)
let rec subst_2_incomplete x s t =
  match t with
  | Var y -> if x = y then s else Var y
  | Con c -> Con c
  | App (t1, t2) -> App (subst_2_incomplete x s t1, subst_2_incomplete x s t2)
  | Abs (y, body) ->
      if x = y then t
      else
        (match body with
         | Abs _ -> failwith "TODO:subst_2_incomplete: nested Abs"
         | App _ -> failwith "TODO:subst_2_incomplete: App in Abs body"
         | _     -> Abs (y, subst_2_incomplete x s body))


(* ========================================================================= *)
(* SECTION 4: GENERATORS & SHRINKERS                                         *)
(* ========================================================================= *)

(* --- The Shrinkers --- *)

let term_size t =
  let rec go = function
    | Con _ | Var _ -> 1
    | App (t1, t2) -> 1 + go t1 + go t2
    | Abs (_, body) -> 1 + go body
  in go t

let rec shrink_term t : term Seq.t =
  let return x = List.to_seq [x] in
  let empty = Seq.empty in
  let (<+>) = Seq.append in
  let (>|=) s f = Seq.map f s in

  (match t with Con 0 -> empty | _ -> return (Con 0))
  <+>
  (match t with
  | Con i -> QCheck2.Shrink.int_towards 0 i >|= fun i' -> Con i'
  | Var _ -> empty
  | App (t1, t2) ->
      return t1 <+> return t2 <+>
      (shrink_term t1 >|= fun t1' -> App (t1', t2)) <+>
      (shrink_term t2 >|= fun t2' -> App (t1, t2'))
  | Abs (x, body) ->
      return (subst_dummy x body) <+>
      (shrink_term body >|= fun body' -> Abs (x, body'))
  )

let rec shrink_term_beta t : term Seq.t =
  let return x = List.to_seq [x] in
  let empty = Seq.empty in
  let (<+>) = Seq.append in
  let (>|=) s f = Seq.map f s in

  (match t with Con 0 -> empty | _ -> return (Con 0))
  <+>
  (match t with
  | Con i -> QCheck2.Shrink.int_towards 0 i >|= fun i' -> Con i'
  | Var _ -> empty
  | App (Abs (x, body), t2) ->
      let reduced = subst_naive x t2 body in
      let try_beta =
        if term_size reduced < term_size t then return reduced
        else empty
      in
      return (Abs (x, body)) <+> return t2 <+>
      try_beta <+>
      (shrink_term_beta (Abs (x, body)) >|= fun t1' -> App (t1', t2)) <+>
      (shrink_term_beta t2 >|= fun t2' -> App (Abs (x, body), t2'))
  | App (t1, t2) ->
      return t1 <+> return t2 <+>
      (shrink_term_beta t1 >|= fun t1' -> App (t1', t2)) <+>
      (shrink_term_beta t2 >|= fun t2' -> App (t1, t2'))
  | Abs (x, body) ->
      return (subst_dummy x body) <+>
      (shrink_term_beta body >|= fun body' -> Abs (x, body'))
  )

(* --- Generator 1: CLOSED Terms (Well-Scoped) --- *)
let term_gen : term G.t =
  let raw_gen =
    G.sized (fun n ->
      G.fix (fun self (n, env, next_id) ->
        if n <= 0 then
          match env with
          | [] -> G.map (fun i -> Con i) G.nat_small
          | _ -> G.oneof_weighted [1, G.map (fun i -> Con i) G.nat_small; 1, G.oneof_list (List.map (fun x -> Var x) env)]
        else
          let base_choices = [
            1, G.map (fun i -> Con i) G.nat_small;
            2, G.map (fun body -> Abs (next_id, body)) (self (n - 1, next_id :: env, next_id + 1));
            3, G.map2 (fun t1 t2 -> App (t1, t2)) (self (n / 2, env, next_id)) (self (n / 2, env, next_id));
          ] in
          match env with
          | [] -> G.oneof_weighted base_choices
          | _ -> G.oneof_weighted ((1, G.oneof_list (List.map (fun x -> Var x) env)) :: base_choices)
      ) (n, [], 0)
    )
  in
  G.set_shrink shrink_term raw_gen

(* --- Generator 2: OPEN Terms (With Free Variables) --- *)
let term_gen_open : term G.t =
  let open G in
  let free_var_pool = List.init 10 (fun i -> i) in (* [0; 1; ...; 9] *)
  let start_id = 0 in

  let raw_gen =
    sized (fun n ->
      fix (fun self (n, env, next_id) ->
        if n <= 0 then
          match env with
          | [] -> map (fun i -> Con i) nat_small
          | _ -> oneof_weighted [1, map (fun i -> Con i) nat_small; 1, oneof_list (List.map (fun x -> Var x) env)]
        else
          let base_choices = [
            1, map (fun i -> Con i) nat_small;
            2, map (fun body -> Abs (next_id, body)) (self (n - 1, next_id :: env, next_id + 1));
            3, map2 (fun t1 t2 -> App (t1, t2)) (self (n / 2, env, next_id)) (self (n / 2, env, next_id));
          ] in
          match env with
          | [] -> oneof_weighted base_choices
          | _ -> oneof_weighted ((1, oneof_list (List.map (fun x -> Var x) env)) :: base_choices)
      ) (n, free_var_pool, start_id)
    )
  in
  G.set_shrink shrink_term raw_gen

(* --- Generator 3: Substitution Triple (Using Open Gen) --- *)
let gen_subst_triple_open =
  let open G in
  term_gen_open >>= fun t ->
  term_gen_open >>= fun s ->
  let fvs = free_vars t in
  let gen_x =
    match fvs with
    | [] -> nat_small
    | vars -> oneof_weighted [1, nat_small; 9, oneof_list vars]
  in
  gen_x >|= fun x -> (x, s, t)

let print_triple' (x, s, t) =
  Printf.sprintf "x: v%d\ns: %s\nt: %s"
    x (print_term s) (print_term t)

let print_triple (x, s, t) =
  Printf.sprintf "replace v%d for %s in: %s"
    x (print_term s) (print_term t)

let print_triple'' (x, s, t) =
  Printf.sprintf "[v%d -> %s]%s"
    x (print_term s) (print_term t)


(* ========================================================================== *)
(* SECTION 5: TESTS                                                           *)
(* ========================================================================== *)

let test_validity =
  QCheck2.Test.make
    ~name:"Generator Validity (Well-Scoped)"
    ~print:print_term
    ~count:10000
    term_gen
    (fun tm ->
      if is_well_scoped tm
      then true
      else QCheck2.Test.fail_reportf "Ill-scoped term: %a" pp_term tm)


let test_shrinker =
  QCheck2.Test.make
    ~name:"Shrinker Validity"
    ~print:print_term
    ~count:1000
    term_gen
    (fun parent_term ->
       let children_seq = shrink_term parent_term in
       let all_valid = ref true in
       Seq.iter (fun child -> if not (is_well_scoped child) then all_valid := false) children_seq;
       !all_valid)

let make_prop_subst_free_no_var_capture_open subst_fn name =
  QCheck2.Test.make
    ~name
    ~print:print_triple
    ~count:1000
    gen_subst_triple_open
    (fun (x, s, t) ->
      let free_t = free_vars t in
      if List.mem x free_t then
        let res = subst_fn x s t in
        let lhs = free_vars res in
        let rhs = set_union (set_remove x free_t) (free_vars s) in
        if set_equal lhs rhs then true
        else
          let captured = List.filter (fun v -> not (List.mem v lhs)) rhs in
          let unexpected = List.filter (fun v -> not (List.mem v rhs)) lhs in
          Printf.printf "FAILURE!\n";
          Printf.printf "  [v%d := %s] %s\n" x (print_term s) (print_term t);
          Printf.printf "  result:   %s\n" (print_term res);
          Printf.printf "  FV(result)   = {%s}\n"
            (String.concat ", " (List.map (fun v -> "v" ^ string_of_int v) (normalize lhs)));
          Printf.printf "  expected FVs = {%s}\n"
            (String.concat ", " (List.map (fun v -> "v" ^ string_of_int v) (normalize rhs)));
          (match captured with
           | [] -> ()
           | _ -> Printf.printf "  captured (should be free but aren't): {%s}\n"
                    (String.concat ", " (List.map (fun v -> "v" ^ string_of_int v) captured)));
          (match unexpected with
           | [] -> ()
           | _ -> Printf.printf "  unexpected (free but shouldn't be): {%s}\n"
                    (String.concat ", " (List.map (fun v -> "v" ^ string_of_int v) unexpected)));
          false
      else true)

let prop_subst_free_no_var_capture_open_subst_naive =
  make_prop_subst_free_no_var_capture_open subst_naive "Capture Avoidance (naive/buggy subst)"

let prop_subst_free_no_var_capture_open_subst_incom =
  make_prop_subst_free_no_var_capture_open subst_incom "Capture Avoidance (correct subst but incomplete)"

let prop_subst_free_no_var_capture_open_subst_mixed =
  make_prop_subst_free_no_var_capture_open subst_mixed "Capture Avoidance (mixed: buggy + incomplete)"

let prop_subst_free_no_var_capture_open_subst_2_incomplete =
  make_prop_subst_free_no_var_capture_open subst_2_incomplete "Capture Avoidance (throws incomplete in 2 branches)"


(* ========================================================================== *)
(* SECTION 6: ALCOTEST ENTRY POINT                                            *)
(* ========================================================================== *)

let () =
  let suite_basic =
    List.map QCheck_alcotest.to_alcotest
      [ test_validity; test_shrinker ]
  in
  let suite_subst =
    List.map QCheck_alcotest.to_alcotest
      [ prop_subst_free_no_var_capture_open_subst_naive;
        prop_subst_free_no_var_capture_open_subst_incom;
        prop_subst_free_no_var_capture_open_subst_mixed;
        prop_subst_free_no_var_capture_open_subst_2_incomplete ]
  in
  Alcotest.run "Lambda Substitution (Incremental PBT)"
    [ "generators", suite_basic;
      "substitution", suite_subst ]
