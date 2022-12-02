open Batteries.Uref
open Util
open Pretty
open Expr
open Eval
open Unif
open Scene
open Pattern

(* source of fresh unification variables, mutable counter is hidden *)
module Fresh : sig
  val uniquei : int
  val freshen : name -> name
  val fresh : mask -> name -> typ
  val freshk : name -> kind
end = struct
  let freshi = ref (-1)
  let uniquei = freshi := !freshi + 1; !freshi
  let freshen (x : name) = x ^ string_of_int uniquei
  let fresh (msk : mask) (x : name) = Inserted (uref (Unsolved (freshen x)), msk)
  let freshk (x : name) = KVar (uref (KUnsolved (freshen x)))
end
open Fresh

exception UndefinedVar of name
exception UndefinedQVar of name
exception Unexpected of typ
exception NoFirstClassTypes of name
exception UnexpectedHigherKind

(* wrapper for [unify] to catch errors *)
let unify' (scn : scene) (t : vtyp) (t' : vtyp) =
  try unify scn.height Global t t' with
  | Ununifiable ->
    let nms = List.map (fun (x, _, _, _) -> x) scn.env in
    let str  = string_of_vtype nms t  in
    let str' = string_of_vtype nms t' in
    raise (Failure ("unable to unify " ^ str ^ " ~/~ " ^ str'))

let infer_lit : lit -> base = function
| `Int _ -> `Int
| `Bool _ -> `Bool

(* construct a closure around a value *)
let clos_of (scn : scene) (t : vtyp) : clos =
  {env = scn.env; bdr = B (quote (inc scn.height) t)}

(* to allow implicit instantiation, we sometimes insert an application for the user *)
let insert (scn : scene) (e, t : expr * vtyp) : expr * vtyp =
  match force t with
  | VForall (x, bod) ->
    let m = fresh (mask_of scn) x in
    let m' = eval scn.env m in
    (Inst (e, m), capp x bod m')
  | t -> (e, t)
let insert_unless (scn : scene) (e, t : expr * vtyp) : expr * vtyp =
  match e with
  | Tlam _ -> (e, t)
  | _ -> insert scn (e, t)

(* embed raw language kinds ↪ core language kinds *)
let rec lower_kind : rkind -> kind = function
| RStar -> Star
| RKArrow (lk, rk) -> KArrow (lower_kind lk, lower_kind rk)

(* elaboration:
   opposed to plain type checking/inference, we want to translate
   the raw language to a more explicit core language.
*)

(* given a type, return its core representation and infer its kind *)
let rec kind_of (scn : scene) : rtyp -> typ * kind = function
| RArrow (lt, rt) -> (Arrow (is_type scn lt, is_type scn rt), Star)
| RBase b -> (Base b, Star)
| RTapp (t1, t2) ->
  let (t1, k1) = kind_of scn t1 in
  let (t2, k2) = kind_of scn t2 in
  let kv = freshk "k" in
  unify_kinds k1 (KArrow (k2, kv));
  (Tapp (t1, t2), kv)
| RTLet (x, k, t, rest) ->
  let (scn, t, vt, k) = infer_let_type scn x k t in
  let (rest, krest) = kind_of (define_typ scn x vt k) rest in
  (TLet (x, t, rest), krest)
| RTAbs (x, None, t) ->
  let kv = freshk "k" in
  let (t, k) = kind_of (assume_typ scn x kv `EUnsolved) t in
  (t, KArrow (kv, k))
| RTAbs (x, Some k, t) ->
  let (t, k') = kind_of scn (RTAbs (x, None, t)) in
  let k = lower_kind k in
  unify_kinds k k';
  (t, k)
| RForall (x, t) ->
  let xk = freshk x in
  let t = is_type (assume_typ scn x xk `EUnsolved) t in
  (Forall (x, B t), Star)
| RHole -> (fresh (mask_of scn) "t", Star)
| RQvar x ->
  match assoc_idx x scn.tctx with
  | Some (i, k) -> (Qvar (Idx i), k)
  | None -> raise (UndefinedQVar x)
and is_type (scn : scene) (t : rtyp) : typ =
  let (t, k) = kind_of scn t in
  unify_kinds k Star;
  t
and maybe_rtyp (scn : scene) (x : name) : rtyp option -> typ = function
| Some t -> is_type scn t
| None -> fresh (mask_of scn) (freshen x)
and maybe_rkind (x : name) : rkind option -> kind = function
| Some k -> lower_kind k
| None -> freshk (freshen x)

and infer_let_type (scn : scene) (x : name) (_ : rkind option) (t : rtyp) : scene * typ * vtyp * kind =
  let (t, k) = kind_of scn t in
  let vt = eval scn.env t in
  (define_typ scn x vt k, t, vt, k)

(* given an expression, return its core representation and infer its type *)
let rec infer (scn : scene) : rexpr -> expr * vtyp = function
| RAnn (e, t) ->
  let (e, te) = insert_unless scn @@ infer scn e in
  let t = eval scn.env (is_type scn t) in
  unify' scn t te;
  (e, te)

| RVar x ->
  begin match assoc_idx x scn.ctx with
  | None -> raise (UndefinedVar x)
  | Some (i, t) -> (Var (Idx i), t)
  end

| RLam (x, None, e) ->
  let tx = eval scn.env (fresh (mask_of scn) x) in
  let (e, te) = infer (assume scn x tx) e in
  (Lam (x, quote scn.height tx, e), VArrow (tx, te))

| RLam (x, Some tx, e) ->
  let tx = eval scn.env (is_type scn tx) in
  let (e, te) = infer (assume scn x tx) e in
  (Lam (x, quote scn.height tx, e), VArrow (tx, te))

| RTlam (x, None, e) ->
  let k = freshk "k" in
  let (e, te) = insert_unless scn @@ infer (assume_typ scn x k `EUnsolved) e in
  (Tlam (x, e), VForall (x, clos_of scn te))

| RTlam (x, Some k, e) ->
  let k = lower_kind k in
  let (e, te) = insert_unless scn @@ infer (assume_typ scn x k `EUnsolved) e in
  (Tlam (x, e), VForall (x, clos_of scn te))

| RApp (e1, e2) ->
  let (e1, te1) = insert scn @@ infer scn e1 in
  let (lt, rt) = begin match force te1 with
  | VArrow (lt, rt) -> (lt, rt)
  | te1 ->
    let lt = eval scn.env (fresh (mask_of scn) "l") in
    let rt = eval scn.env (fresh (mask_of scn) "r") in
    unify' scn te1 (VArrow (lt, rt));
    (lt, rt)
  end in
  let e2 = check scn e2 lt in
  (App (e1, e2), rt)

| RInst (e, t) ->
  let (e, te) = infer scn e in
  let (t, k) = kind_of scn t in

  let x = freshen "x" in
  let ret = fresh (mask_of (assume_typ scn x k `ESolved)) "ret" in
  let clos = {env = scn.env; bdr = B ret} in

  unify' scn te (VForall (x, clos));
  (Inst (e, t), capp x clos (eval scn.env t))

| RLet (rc, x, ps, t, e, rest) ->
  let (scn, _, e, te) = infer_let scn rc x ps t e in
  let (rest, trest) = infer (assume scn x te) rest in
  (Let (rc, x, quote scn.height te, e, rest), trest)

| RMatch (scrut, branches) ->
  check_coverage scn branches;
  let (scrut, scrut_typ) = infer scn scrut in
  let t = eval scn.env (fresh (mask_of scn) "t") in
  let branch_typs = List.map (fun (pat, branch) -> infer_branch scn scrut_typ pat branch) branches in
  ignore @@ List.map (fun (_, _, t') -> unify' scn t t') branch_typs;
  (Match (scrut, List.map (fun (p, e, _) -> (p, e)) branch_typs), t)

| RLit n ->
  (Lit n, VBase (infer_lit n))

and check (scn : scene) (e : rexpr) (t : vtyp) : expr = match e, force t with
| RLam (x, Some xt, e), VArrow (lt, rt) ->
  let xt = eval scn.env (is_type scn xt) in
  unify' scn xt lt;
  check scn (RLam (x, None, e)) (VArrow (lt, rt))
  
| RLam (x, None, e), VArrow (lt, rt) ->
  let e = check (assume scn x lt) e rt in
  Lam (x, quote scn.height lt, e)

| RTlam (x, Some _, e), VForall (x', c) ->
  (*todo unify k with the kind of x'*)
  check scn (RTlam (x, None, e)) (VForall (x', c))

| RTlam (x, None, e), VForall (x', c) ->
  let ret_typ = cinst_at scn.height x' c in
  let e = check (assume_typ scn x Star (*todo kind annotation on x'*) `EUnsolved) e ret_typ in
  Tlam (x, e)

| RLet (rc, x, ps, t, e, rest), t_rest ->
  let (scn, _, e, te) = infer_let scn rc x ps t e in
  let rest = check scn rest t_rest in
  Let (rc, x, quote scn.height te, e, rest)

| RMatch (scrut, branches), ret_typ ->
  check_coverage scn branches;
  let (scrut, scrut_typ) = infer scn scrut in
  let branch_typs = List.map (fun (pat, branch) -> check_branch scn scrut_typ pat branch ret_typ) branches in
  Match (scrut, branch_typs)
  
| e, actual_t ->
  let (e, expected_t) = insert_unless scn @@ infer scn e in
  unify' scn expected_t actual_t;
  e

(* given a scene, a list of parameters, and a return type, return
- a new scene, with the bound params in scope
- the whole type of the function being defined
- just the return type of the function being defined (evaluated under the new scene)
*)
and process_params (scn : scene) (ps : rparam list) (ret_typ : rtyp option) : scene * typ * vtyp =
  match ps with
  | [] ->
    let ret_typ = maybe_rtyp scn "ret" ret_typ in
    (scn, ret_typ, eval scn.env ret_typ)
  | RParam (x, t) :: ps ->
    let t = maybe_rtyp scn x t in
    let scn = assume scn x (eval scn.env t) in
    let (scn, all_typ, ret_typ) = process_params scn ps ret_typ in
    (scn, Arrow (t, all_typ), ret_typ)
  | RTParam (x, k) :: ps ->
    let k = maybe_rkind x k in
    let scn = assume_typ scn x k `EUnsolved in
    let (scn, all_typ, ret_typ) = process_params scn ps ret_typ in
    (scn, Forall (x, B all_typ), ret_typ)

(* compute the scene representing a [let]'s inner scope, with all parameters bound.
  also returns the entire binding's type, and just its return type (without parameters)
*)
and scene_of_let (scn : scene) (rc : bool) (x : name) (ps : rparam list) (ret_typ : rtyp option) : scene * vtyp * vtyp =
  let (inner_scn, all_typ, ret_typ) = process_params scn ps ret_typ in
  let all_typ = eval scn.env all_typ in
  let inner_scn = if rc then assume inner_scn x all_typ else inner_scn in
  (inner_scn, all_typ, ret_typ)

(* returns first the scope after the [let], and second the [let]'s inner scope *)
and infer_let (scn : scene) (rc : bool) (x : name) (ps : rparam list) (t : rtyp option) (e : rexpr) : scene * scene * expr * vtyp =
  (* if the binding is recursive, extend the scene with it *)
  let (inner_scn, all_typ, ret_typ) = scene_of_let scn rc x ps t in
  let e = check inner_scn e ret_typ in
  (assume scn x all_typ, inner_scn, e, all_typ)

and infer_branch (scn : scene) (scrut_typ : vtyp) (pat : pattern) (branch : rexpr) : pattern * expr * vtyp =
  let (pat, scn) = scene_of_pattern scn scrut_typ pat in
  let (branch, branch_typ) = infer scn branch in
  (pat, branch, branch_typ)

and check_branch (scn : scene) (scrut_typ : vtyp) (pat : pattern) (branch : rexpr) (ret_typ : vtyp) : pattern * expr =
  let (pat, scn) = scene_of_pattern scn scrut_typ pat in
  let ret_typ = vnorm scn.env ret_typ in
  let branch = check scn branch ret_typ in
  (pat, branch)

(* get the last type in a chain of arrows (including foralls) *)
let rec return_type (hi : lvl) : vtyp -> vtyp = function
| VArrow (_, t) -> return_type hi t
| VForall (x, c) -> return_type (inc hi) (cinst_at hi x c)
| t -> t

(* modify the scene with a new data declaration and its constructors *)
exception BadCtorReturn
let declare_ctor (parent : lvl) (scn : scene) (Ctor {nam; t} : rctor) : scene =
  let t = is_type scn t in
  let vt = eval scn.env t in
  let rett = return_type scn.height (eval scn.env t) in (* ctor's return type must be the data it belongs to *)
  match rett with
  | VNeut (VQvar i, _) when parent = i -> assume scn nam vt
  | _ -> raise BadCtorReturn
let declare_data (scn : scene) (x : name) (k : rkind option) (ctors : rctor list) =
  let k = maybe_rkind (freshen "k") k in
  let parent = scn.height in (* slightly hacky: get the height before [assume_typ], will be the lvl of the type just defined *)
  let scn = assume_typ scn x k `ESolved in
  let scn = List.fold_left (declare_ctor parent) scn ctors in
  define_ctors scn x (List.map (fun (Ctor {nam; _}) -> nam) ctors)