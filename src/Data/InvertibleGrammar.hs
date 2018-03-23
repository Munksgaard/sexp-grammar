{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE DeriveFoldable        #-}
{-# LANGUAGE DeriveTraversable     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}

module Data.InvertibleGrammar
  ( Grammar (..)
  , (:-) (..)
  , iso
  , osi
  , partialIso
  , partialOsi
  , push
  , pushForget
  , octopus
  , forward
  , backward
  , GrammarError (..)
  , Mismatch
  , expected
  , unexpected
  ) where

import Prelude hiding ((.), id)
#if defined(__GLASGOW_HASKELL__) && __GLASGOW_HASKELL__ < 710
import Control.Applicative
#endif
import Control.Category
import Control.Monad
import Data.Map (Map)
import qualified Data.Map as M
import Data.Bifunctor
import Data.Bifoldable
import Data.Bitraversable
#if !MIN_VERSION_base(4,11,0)
import Data.Semigroup
#endif
import Data.InvertibleGrammar.Monad


data Grammar p a b where
  Iso        :: (a -> b) -> (b -> a) -> Grammar p a b
  PartialIso :: (a -> b) -> (b -> Either Mismatch a) -> Grammar p a b
  Flip       :: Grammar p a b -> Grammar p b a
  (:.:)      :: Grammar p b c -> Grammar p a b -> Grammar p a c
  (:<>:)     :: Grammar p a b -> Grammar p a b -> Grammar p a b
  Traverse   :: (Traversable f) => Grammar p a b -> Grammar p (f a) (f b)
  Bitraverse :: (Bitraversable f) => Grammar p a b -> Grammar p c d -> Grammar p (f a c) (f b d)

  Octopus    :: (Ord (idx a), Ord (idx' b)) =>
                (a -> idx  a) -> Map (idx  a) (Grammar p (a :- t) (b :- t))
             -> (b -> idx' b) -> Map (idx' b) (Grammar p (a :- t) (b :- t))
             -> Grammar p (a :- t) (b :- t)

  Dive       :: Grammar p a b -> Grammar p a b
  Step       :: Grammar p a a
  Locate     :: Grammar p p p


instance Category (Grammar p) where
  id = Iso id id
  Iso f g        . Iso f' g' = Iso (f . f') (g' . g)
  PartialIso f g . Iso f' g' = PartialIso (f . f') (fmap g' . g)
  Iso f g        . PartialIso f' g' = PartialIso (f . f') (g' . g)
  PartialIso f g . PartialIso f' g' = PartialIso (f . f') (g' <=< g)
  Flip (PartialIso f g) . Flip (PartialIso f' g') = Flip (PartialIso (f' . f) (g <=< g'))
  g . h = g :.: h

instance Semigroup (Grammar p a b) where
  (<>) = (:<>:)

data h :- t = h :- t deriving (Eq, Show, Functor, Foldable, Traversable)
infixr 5 :-

instance Bifunctor (:-) where
  bimap f g (a :- b) = (f a :- g b)

instance Bifoldable (:-) where
  bifoldr f g x0 (a :- b) = a `f` (b `g` x0)

instance Bitraversable (:-) where
  bitraverse f g (a :- b) = (:-) <$> f a <*> g b


-- | Make a grammar from a total isomorphism on top element of stack
iso :: (a -> b) -> (b -> a) -> Grammar p (a :- t) (b :- t)
iso f' g' = Iso f g
  where
    f (a :- t) = f' a :- t
    g (b :- t) = g' b :- t


-- | Make a grammar from a total isomorphism on top element of stack (flipped)
osi :: (b -> a) -> (a -> b) -> Grammar p (a :- t) (b :- t)
osi f' g' = Iso g f
  where
    f (a :- t) = f' a :- t
    g (b :- t) = g' b :- t


-- | Make a grammar from a partial isomorphism which can fail during backward
-- run
partialIso :: (a -> b) -> (b -> Either Mismatch a) -> Grammar p (a :- t) (b :- t)
partialIso f' g' = PartialIso f g
  where
    f (a :- t) = f' a :- t
    g (b :- t) = (:- t) <$> g' b


-- | Make a grammar from a partial isomorphism which can fail during forward run
partialOsi :: (b -> a) -> (a -> Either Mismatch b) -> Grammar p (a :- t) (b :- t)
partialOsi f' g' = Flip $ PartialIso f g
  where
    f (a :- t) = f' a :- t
    g (b :- t) = (:- t) <$> g' b


-- | Unconditionally push given value on stack, i.e. it does not consume
-- anything on parsing. However such grammar expects the same value as given one
-- on the stack during backward run.
push :: (Eq a) => a -> Grammar p t (a :- t)
push a = PartialIso f g
  where
    f t = a :- t
    g (a' :- t)
      | a == a' = Right t
      | otherwise = Left $ unexpected "pushed element"


-- | Same as 'push' except it does not check the value on stack during backward
-- run. Potentially unsafe as it \"forgets\" some data.
pushForget :: a -> Grammar p t (a :- t)
pushForget a = Iso f g
  where
    f t = a :- t
    g (_ :- t) = t


octopus :: (Ord (idx a), Ord (idx' b)) => (a -> idx a) -> (b -> idx' b) -> [(idx a, idx' b, Grammar p (a :- t) (b :- t))] -> Grammar p (a :- t) (b :- t)
octopus ta tb lst =
  let as = M.fromListWith (<>) $ map (\(a, _, g) -> (a, g)) lst
      bs = M.fromListWith (<>) $ map (\(_, b, g) -> (b, g)) lst
  in Octopus ta as tb bs


forward :: Grammar p a b -> a -> ContextError (Propagation p) (GrammarError p) b
forward (Iso f _)        = return . f
forward (PartialIso f _) = return . f
forward (Flip g)         = backward g
forward (g :.: f)        = forward g <=< forward f
forward (f :<>: g)       = \x -> forward f x `mplus` forward g x
forward (Traverse g)     = traverse (forward g)
forward (Bitraverse g h) = bitraverse (forward g) (forward h)
forward (Octopus f mg _ _) = \x@(a :- _) ->
  case M.lookup (f a) mg of
    Nothing -> throwInContext (\ctx -> GrammarError ctx (unexpected "unhandled case"))
    Just g  -> forward g x
forward (Dive g)         = dive . forward g
forward Step             = \x -> step >> return x
forward Locate           = \x -> locate x >> return x
{-# INLINE forward #-}


backward :: Grammar p a b -> b -> ContextError (Propagation p) (GrammarError p) a
backward (Iso _ g)        = return . g
backward (PartialIso _ g) = either (\mis -> throwInContext (\ctx -> GrammarError ctx mis)) return . g
backward (Flip g)         = forward g
backward (g :.: f)        = backward g >=> backward f
backward (f :<>: g)       = \x -> backward f x `mplus` backward g x
backward (Traverse g)     = traverse (backward g)
backward (Bitraverse g h) = bitraverse (backward g) (backward h)
backward (Octopus _ _ f mg) = \x@(a :- _) ->
  case M.lookup (f a) mg of
    Nothing -> throwInContext (\ctx -> GrammarError ctx (unexpected "unhandled case"))
    Just g  -> backward g x
backward (Dive g)         = dive . backward g
backward Step             = \x -> step >> return x
backward Locate           = \x -> locate x >> return x
{-# INLINE backward #-}
