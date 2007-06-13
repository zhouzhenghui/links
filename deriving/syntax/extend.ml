(*pp camlp4of *)
(* Extend the OCaml grammar to include the `deriving' clause after
   type declarations in structure and signatures. *)

open Utils

module Deriving (Syntax : Camlp4.Sig.Camlp4Syntax) =
struct
  open Camlp4.PreCast

  include Syntax

  let derive proj (loc : Loc.t) tdecls classname =
    try 
      let context = Base.setup_context loc tdecls in
        proj (Base.find classname) (loc, context, tdecls)
    with
        Base.Underivable msg | Failure msg ->
          Syntax.print_warning loc msg;
          exit 1
  
  let derive_str loc (tdecls : Type.decl list) classname =
    derive fst loc tdecls classname
  
  let derive_sig loc tdecls classname =
    derive snd loc tdecls classname


  DELETE_RULE Gram str_item: "type"; type_declaration END
  DELETE_RULE Gram sig_item: "type"; type_declaration END

  open Ast

  EXTEND Gram
  str_item:
  [[ "type"; types = type_declaration -> <:str_item< type $types$ >>
    | "type"; types = type_declaration; "deriving"; "("; cl = LIST0 [x = UIDENT -> x] SEP ","; ")" ->
        let decls = Type.Translate.decls types in 
        let module U = Type.Untranslate(struct let loc = loc end) in
        let tdecls : Ast.ctyp list = List.map U.decl decls in
          <:str_item< type $list:tdecls$ $list:List.map (derive_str loc decls) cl$ >>
   ]]
  ;
  sig_item:
  [[ "type"; types = type_declaration -> <:sig_item< type $types$ >>
   | "type"; types = type_declaration; "deriving"; "("; cl = LIST0 [x = UIDENT -> x] SEP "," ; ")" ->
       let decls : Type.decl list = Type.Translate.decls types in 
       let module U = Type.Untranslate(struct let loc = loc end) in
       let tdecls : Ast.ctyp list = List.map U.sigdecl decls in
       let ms = List.map (derive_sig loc decls) cl in
         <:sig_item< type $list:tdecls$ $list:ms$ >> ]]
  ;
  END
end

module M = Camlp4.Register.OCamlSyntaxExtension(Id)(Deriving)
