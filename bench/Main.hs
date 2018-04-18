{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeOperators      #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main (main) where

import Criterion.Main

import Prelude hiding ((.), id)

import Control.Arrow
import Control.Category
import Control.DeepSeq
import Control.Exception

import Data.Data (Data, Typeable)
import qualified Data.Text.Lazy as TL
import GHC.Generics (Generic)

import Data.InvertibleGrammar

import Language.Sexp (Sexp, Atom, Kw, Position)
import Language.SexpGrammar
import qualified Language.SexpGrammar.TH as TH
import qualified Language.SexpGrammar.Generic as G
import Language.SexpGrammar.Generic (Coproduct(..))

newtype Ident = Ident String
  deriving (Show, Eq, Generic)

data Expr
  = Var Ident
  | Lit Int
  | Add Expr Expr
  | Mul Expr Expr
  | Inv Expr
  | IfZero Expr Expr (Maybe Expr)
  | Apply [Expr] String Prim -- inconvenient ordering: arguments, useless annotation, identifier
    deriving (Show, Eq, Generic)

data Prim
  = SquareRoot
  | Factorial
  | Fibonacci
    deriving (Show, Eq, Enum, Bounded, Data, Typeable, Generic)

instance NFData Ident
instance NFData Prim
instance NFData Expr

instance NFData Atom
instance NFData Kw
instance NFData Position
instance NFData Sexp

return []

type SexpG a = forall t. Grammar Position (Sexp :- t) (a :- t)

instance SexpIso Prim where
  sexpIso = enum

instance SexpIso Ident where
  sexpIso = $(TH.match ''Ident)
    (\_Ident -> _Ident . symbol')

exprGrammarTH :: SexpG Expr
exprGrammarTH = go
  where
    go :: SexpG Expr
    go = $(TH.match ''Expr)
      (\_Var -> _Var . sexpIso)
      (\_Lit -> _Lit . int)
      (\_Add -> _Add . list (el (sym "+") >>> el go >>> el go))
      (\_Mul -> _Mul . list (el (sym "*") >>> el go >>> el go))
      (\_Inv -> _Inv . list (el (sym "invert") >>> el go))
      (\_IfZero -> _IfZero . list (el (sym "cond") >>> props ( Kw "pred"  .:  go
                                                           >>> Kw "true"  .:  go
                                                           >>> Kw "false" .:? go )))
      (\_Apply -> _Apply .              -- Convert prim :- "dummy" :- args :- () to Apply node
          list
           (el (sexpIso :: SexpG Prim) >>>       -- Push prim:       prim :- ()
            el (kw (Kw "args")) >>>              -- Recognize :args, push nothing
            rest (go :: SexpG Expr) >>>     -- Push args:       args :- prim :- ()
            Traverse (
               swap >>>                             -- Swap:            prim :- args :- ()
               push "dummy" >>>                     -- Push "dummy":    "dummy" :- prim :- args :- ()
               swap)                                -- Swap:            prim :- "dummy" :- args :- ()
           ))

exprGrammarGeneric :: SexpG Expr
exprGrammarGeneric = go
  where
    go :: SexpG Expr
    go = G.match
      $ With (\_Var -> _Var . sexpIso)
      $ With (\_Lit -> _Lit . int)
      $ With (\_Add -> _Add . list (el (sym "+") >>> el go >>> el go))
      $ With (\_Mul -> _Mul . list (el (sym "*") >>> el go >>> el go))
      $ With (\_Inv -> _Inv . list (el (sym "invert") >>> el go))
      $ With (\_IfZero -> _IfZero . list (el (sym "cond") >>> props ( Kw "pred"  .:  go
                                                                  >>> Kw "true"  .:  go
                                                                  >>> Kw "false" .:? go )))
      $ With (\_Apply -> _Apply .              -- Convert prim :- "dummy" :- args :- () to Apply node
                list
                 (el (sexpIso :: SexpG Prim) >>>       -- Push prim:       prim :- ()
                  el (kw (Kw "args")) >>>              -- Recognize :args, push nothing
                  rest (go :: SexpG Expr) >>>     -- Push args:       args :- prim :- ()
                  Traverse (
                     swap >>>                             -- Swap:            prim :- args :- ()
                     push "dummy" >>>                     -- Push "dummy":    "dummy" :- prim :- args :- ()
                     swap)                                -- Swap:            prim :- "dummy" :- args :- ()
                 ))
      $ End


exprGrammarSelect :: SexpG Expr
exprGrammarSelect = go
  where
    go :: SexpG Expr
    go = select
      [ ( ConstTag
        , mkTag (Var undefined) :: Tag Expr
        , $(TH.grammarFor 'Var) . sexpIso
        )
      , ( ConstTag
        , mkTag (Lit undefined)
        , $(TH.grammarFor 'Lit) . int
        )
      , ( ConstTag
        , mkTag (Add undefined undefined)
        , $(TH.grammarFor 'Add) . list (el (sym "+") >>> el go >>> el go)
        )
      , ( ConstTag
        , mkTag (Mul undefined undefined)
        , $(TH.grammarFor 'Mul) . list (el (sym "*") >>> el go >>> el go)
        )
      , ( ConstTag
        , mkTag (Inv undefined)
        , $(TH.grammarFor 'Inv) . list (el (sym "invert") >>> el go)
        )
      , ( ConstTag
        , mkTag (IfZero undefined undefined undefined)
        , $(TH.grammarFor 'IfZero) . list (
              el (sym "cond") >>>
              props ( Kw "pred"  .:  go >>>
                      Kw "true"  .:  go >>>
                      Kw "false" .:? go))
        )
      , ( ConstTag
        , mkTag (Apply undefined undefined undefined)
        , $(TH.grammarFor 'Apply) .
          list (
            el (sexpIso :: SexpG Prim) >>>
            el (kw (Kw "args")) >>>
            rest go >>>
            Traverse (swap >>> push "dummy" >>> swap))
        )
      ]


expr :: TL.Text -> Expr
expr = either error id . decodeWith exprGrammarTH

benchCases :: [(String, TL.Text)]
benchCases = map (\a -> ("expression, size " ++ show (TL.length a) ++ " bytes", a))
  [ "(+ 1 20)"
  , "(cond :pred (+ 42 x) :false (fibonacci :args 3) :true (factorial :args (* 10 (+ 1 2))))"
  , "(invert (* (+ (cond :pred (+ 42 314) :false (fibonacci :args 3) :true (factorial :args \
    \(* 10 (+ 1 2)))) (cond :pred (+ 42 28) :false (fibonacci :args 3) :true (factorial :args \
    \(* 10 (+ 1 2))))) (+ (cond :pred (+ 42 314) :false (fibonacci :args 3) :true (factorial \
    \:args (* 10 (+ foo bar)))) (cond :pred (+ 42 314) :false (fibonacci :args 3) :true (factorial \
    \:args (* 10 (+ 1 2)))))))"
  ]

mkBenchmark :: String -> TL.Text -> IO Benchmark
mkBenchmark name str = do
  expr <- evaluate $ force $ expr str
  sexp <- evaluate $ force $ either error id (genSexp exprGrammarTH expr)
  return $ bgroup name
    [ bench "gen"    $ nf (genSexp exprGrammarTH) expr
    , bench "genG"   $ nf (genSexp exprGrammarGeneric) expr
    , bench "genS"   $ nf (genSexp exprGrammarSelect) expr
    , bench "parse"  $ nf (parseSexp exprGrammarTH) sexp
    , bench "parseG" $ nf (parseSexp exprGrammarGeneric) sexp
    , bench "parseS" $ nf (parseSexp exprGrammarSelect) sexp
    ]

main :: IO ()
main = do
  cases <- mapM (uncurry mkBenchmark) benchCases
  defaultMain cases
