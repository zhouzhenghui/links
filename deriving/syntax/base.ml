(*pp camlp4of *)
open Utils
open Types
open Camlp4.PreCast
module NameMap = StringMap
module NameSet = Set.Make(String)

type context = {
  loc : Loc.t;
  (* mapping from type parameters to functor arguments *)
  argmap : name NameMap.t;
  (* ordered list of type parameters *)
  params : param list;
}


exception Underivable of string
exception NoSuchClass of string


(* display a fatal error and exit *)
let error loc (msg : string) =
  Syntax.print_warning loc msg;
  exit 1

(*
module type Context = sig val context: context end
module type TContext = sig include Context val tcontext : type_context end
*)
module type Loc = sig val loc : Loc.t end

module InContext(L : Loc) =
struct
  include L
  module Untranslate = Untranslate(L)

  let instantiate (lookup : name -> expr) : expr -> expr =
    let rec inst = function
      | Param (name, _) -> lookup name 
      | Underscore      -> Underscore
      | Function (l, r) -> Function (inst l, inst r)
      | Constr (c, ts)  -> Constr (c, List.map inst ts)
      | Tuple es        -> Tuple (List.map inst es)
      | Alias (e, n)    -> Alias (inst e, n)
      | Variant (v, ts) -> Variant (v, List.map inst_tag ts)
      | _ -> assert false
    and inst_tag = function
      | Tag (n, Some t) ->  Tag (n, Some (inst t))
      | Tag _ as t -> t
      | Extends t -> Extends (inst t)
    in inst

  let instantiate_modargs ctxt t =
    let lookup var = 
      try 
        Constr ([NameMap.find var ctxt.argmap; "a"], [])
      with Not_found ->
        failwith ("Unbound type parameter '" ^ var)
    in instantiate lookup t

  let random_id length = 
    let idchars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_'" in
    let nidchars = String.length idchars in
    let s = String.create length in 
      for i = 0 to length - 1 do 
        s.[i] <- idchars.[Random.int nidchars]
      done;
      s

  let contains_tvars : expr -> bool = 
    (object
       inherit [bool] fold as default
       method crush = List.exists (fun x -> x)
       method expr = function
         | Param _ -> true
         | e -> default#expr e
     end) # expr

  let substitute env =
    (object
       inherit transform as default
       method expr = function
         | Param (p,v) when NameMap.mem p env -> 
             Param (NameMap.find p env,v)
         | e -> default# expr e
     end) # expr

  let cast_pattern ctxt ?(param="x") t = 
    let t = Untranslate.expr (instantiate_modargs ctxt t) in
      (<:patt< $lid:param$ >>,
       <:expr<
         let module M = 
             struct
               type t = $t$
               let test = function #t -> True | _ -> False
             end in M.test $lid:param$ >>,
       <:expr<
         (let module M = 
              struct
                type t = $t$
                let cast = function #t as t -> t | _ -> assert False
              end in M.cast $lid:param$ )>>)

  let seq l r = <:expr< $l$ ; $r$ >>

  let record_pattern ?(prefix="") : Types.field list -> Ast.patt = 
    fun fields ->
      List.fold_left1
        (fun l r -> <:patt< $l$ ; $r$ >>)
        (List.map (fun (label,_,_) -> <:patt< $lid:label$ = $lid:prefix ^ label$ >>) 
           fields)

  let record_expr : (string * Ast.expr) list -> Ast.expr = 
    fun fields ->
      List.fold_left1 
        (fun l r -> <:expr< $l$ ; $r$ >>)
        (List.map (fun (label, exp) -> <:expr< $lid:label$ = $exp$ >>) 
           fields)


  let record_expression ?(prefix="") : Types.field list -> Ast.expr = 
    fun fields ->
      List.fold_left1
        (fun l r -> <:expr< $l$ ; $r$ >>)
        (List.map (fun (label,_,_) -> <:expr< $lid:label$ = $lid:prefix ^ label$ >>) 
           fields)

  let tuple_expr : Ast.expr list -> Ast.expr = function
    | [] -> <:expr< () >>
    | [x] -> x
    | x::xs -> let cs l r = <:expr< $l$, $r$ >> in
        <:expr< $List.fold_left cs x xs$ >>

  let tuple ?(param="v") n : Ast.patt * Ast.expr =
    let v n = Printf.sprintf "%s%d" param n in
      match n with
        | 0 -> <:patt< () >>, <:expr< () >>
        | 1 -> <:patt< $lid:v 0$ >>, <:expr< $lid:v 0$ >>
        | n -> List.fold_right1
            (fun (p1,e1) (p2,e2) -> <:patt< $p1$, $p2$ >>, <:expr< $e1$, $e2$ >>)
              (List.map 
                 (fun n -> <:patt< $lid:v n$ >>, <:expr< $lid:v n$ >>)
                 (List.range 0 n))

  let rec modname_from_qname ~qname ~classname =
    match qname with 
      | [] -> invalid_arg "modname_from_qname"
      | [t] -> <:ident< $uid:classname ^ "_"^ t$ >>
      | t::ts -> <:ident< $uid:t$.$modname_from_qname ~qname:ts ~classname$ >>
          
  class make_module_expr ~classname ~variant ~record ~sum =
  object (self)

    method mapply ctxt (funct : Ast.module_expr) args =
      List.fold_left
        (fun funct param -> <:module_expr< $funct$ $self#expr ctxt param$ >>)
        funct
        args

    method variant = variant
    method sum = sum
    method record = record

    method param ctxt (name, variance) =
      <:module_expr< $uid:NameMap.find name ctxt.argmap$ >>

    method underscore _  = raise (Underivable (classname ^ " cannot be derived for types with `_'"))
    method object_   _ o = raise (Underivable (classname ^ " cannot be derived for object types"))
    method class_    _ c = raise (Underivable (classname ^ " cannot be derived for class types"))
    method alias     _ a = raise (Underivable (classname ^ " cannot be derived for `as' types"))
    method label     _ l = raise (Underivable (classname ^ " cannot be derived for label types"))
    method function_ _ f = raise (Underivable (classname ^ " cannot be derived for function types"))

    method constr ctxt (qname, args) = 
      let f = (modname_from_qname ~qname ~classname) in
        self#mapply ctxt (Ast.MeId (loc, f)) args

    method tuple ctxt = function
        | [] -> <:module_expr< $uid:Printf.sprintf "%s_unit" classname$ >>
        | [a] -> self#expr ctxt a
        | args -> 
            let f = <:module_expr< $uid:Printf.sprintf "%s_%d" 
                                   classname (List.length args)$ >> in
              self#mapply ctxt f args

    method expr (ctxt : context) : expr -> Ast.module_expr = function
      | Param p    -> self#param      ctxt p
      | Underscore -> self#underscore ctxt
      | Object o   -> self#object_    ctxt o
      | Class c    -> self#class_     ctxt c
      | Alias a    -> self#alias      ctxt a
      | Label l    -> self#label      ctxt l 
      | Function f -> self#function_  ctxt f
      | Constr c   -> self#constr     ctxt c
      | Tuple t    -> self#tuple      ctxt t
      | Variant v  -> self#variant    ctxt v

    method rhs ctxt (tname, params, rhs, constraints  as decl : Types.decl) : Ast.module_expr = 
      match rhs with
        | `Fresh (None, Sum summands) -> self#sum ctxt decl summands
        | `Fresh (None, Record fields) -> self#record ctxt decl fields
        | `Alias e -> self#expr ctxt e
  end

  let atype ctxt (name, params, _, _) = 
    Untranslate.expr (Constr ([name],
                              List.map (fun (p,_) -> Constr ([NameMap.find p ctxt.argmap; "a"],[])) params))

  let atypev _ _ = failwith "atypev nyi"

  let generate ~context ~decls ~make_module_expr ~classname ?default_module () =
    (* plan: 
       set up an enclosing recursive module
       generate functors for all types in the clique
       project out the inner modules afterwards.
       
       later: generate simpler code for simpler cases:
       - where there are no type parameters
       - where there's only one type
       - where there's no recursion
       - etc.
    *)
    let params = context.params in
      (*    let _ = ensure_no_polymorphic_recursion in *)
    let wrapper_name = Printf.sprintf "%s_%s" classname (random_id 32)  in
    let make_functor = 
      List.fold_right 
        (fun (p,_) rhs -> 
           let arg = NameMap.find p context.argmap in
             <:module_expr< functor ($arg$ : $uid:classname$.$uid:classname$) -> $rhs$ >>)
        params in
    let apply_defaults mexpr = match default_module with
      | None -> mexpr
      | Some default -> <:module_expr< $uid:classname$.$uid:default$ ($mexpr$) >> in
    let mbinds =
      List.map 
        (fun (name,params,rhs,constraints as decl) -> 
           <:module_binding< 
             $uid:classname ^ "_"^ name$
             : $uid:classname$.$uid:classname$ with type a = $atype context decl$
          = $apply_defaults (make_module_expr context decl)$ >>)
        decls in
    let mrec =
      <:str_item< module rec $list:mbinds$ >> in
    let fixed = make_functor <:module_expr< struct $mrec$ end >> in
    let projected =
      List.map (fun (name,params,rhs,constraints) -> 
                  let modname = classname ^ "_"^ name in
                  let rhs = <:module_expr< $uid:wrapper_name$ . $uid:modname$ >> in
                    <:str_item< module $uid:modname$ = $make_functor rhs$>>)
        decls in
    let m = <:str_item< module $uid:wrapper_name$ = $fixed$ >> in
      <:str_item< $m$ $List.hd projected$ >>
end
   
let extract_params = 
  let has_params params (_, ps, _, _) = ps = params in
    function
      | [] -> invalid_arg "extract_params"
      | (_,params,_,_)::rest
          when List.for_all (has_params params) rest ->
          params
      | (_,_,rhs,_)::_ -> 
          (* all types in a clique must have the same parameters *)
          raise (Underivable ("Instances can only be derived for "
                             ^"recursive groups where all types\n"
                             ^"in the group have the same parameters."))

let setup_context loc (types : Ast.ctyp list) : context =
  let tdecls = List.map Translate.decl types in
  let params = extract_params tdecls in
  let argmap = 
    List.fold_right
      (fun (p,_) m -> NameMap.add p (Printf.sprintf "V_%s" p) m)
      params
      NameMap.empty in 
    { loc = loc;
      argmap = argmap;
      params = params; } 
      
type deriver = Loc.t * context * Types.decl list -> Ast.str_item
let derivers : (name, deriver) Hashtbl.t = Hashtbl.create 15
let register c = 
  prerr_endline ("registering " ^ c);
  Hashtbl.add derivers c
let find classname = 
  try Hashtbl.find derivers classname
  with Not_found -> raise (NoSuchClass classname)