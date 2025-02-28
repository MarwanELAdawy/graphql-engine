{-# LANGUAGE Arrows #-}

-- |
-- = TL;DR
--
-- We go from this:
--
-- > (|
-- >   withRecordInconsistency
-- >     ( (|
-- >         modifyErrA
-- >           ( do
-- >               (info, dependencies) <- liftEitherA -< buildRelInfo relDef
-- >               recordDependencies -< (metadataObject, schemaObject, dependencies)
-- >               returnA -< info
-- >           )
-- >       |) (addTableContext @b table . addRelationshipContext)
-- >     )
-- >   |) metadataObject
--
-- to this:
--
-- > withRecordInconsistencyM metadataObject $ do
-- >   modifyErr (addTableContext @b table . addRelationshipContext) $ do
-- >     (info, dependencies) <- liftEither $ buildRelInfo relDef
-- >     recordDependenciesM metadataObject schemaObject dependencies
-- >     return info
--
-- = Background
--
-- We use Haskell's @Arrows@ language extension to gain some syntactic sugar when
-- working with `Arrow`s. `Arrow`s are a programming abstraction comparable to
-- `Monad`s.
--
-- Unfortunately the syntactic sugar provided by this language extension is not
-- very sweet.
--
-- This module allows us to sometimes avoid using @Arrows@ syntax altogether,
-- without loss of functionality or correctness. It is a demo of a technique that
-- can be used to cut down the amount of @Arrows@-based code in our codebase by
-- about half.
--
-- = Approach
--
-- Although /in general/ not every `Monad` is an `Arrow`, specific `Arrow`
-- instantiations are exactly as powerful as their `Monad` equivalents. Otherwise
-- they wouldn't be very equivalent, would they?
--
-- Just like `liftEither` interprets the @`Either` e@ monad into an arbitrary monad
-- implementing @`MonadError` e@, we add `interpA` which interprets certain
-- concrete monads such as @`Control.Monad.Trans.Writer.CPS.Writer` w@ into arrows
-- satisfying constraints, in this example the ones satisfying @`ArrowWriter` w@.
-- This means that the part of the code that only uses such interpretable arrow
-- effects can be written /monadically/, and then used in /arrow/ constructions
-- down the line.
--
-- This approach cannot be used for arrow effects which do not have a monadic
-- equivalent. In our codebase, the only instance of this is
-- @`Hasura.Incremental.ArrowCache` m@, implemented by the
-- @`Hasura.Incremental.Rule` m@ arrow. So code written with
-- @`Hasura.Incremental.ArrowCache` m@ in the context cannot be rewritten
-- monadically using this technique.
module Control.Arrow.Interpret
  ( ArrowInterpret (..),
  )
where

import Control.Arrow
import Control.Arrow.Extended
import Control.Monad.Trans.Except
import Control.Monad.Trans.Reader
import Data.Functor.Identity
import Hasura.Prelude

-- | Translate the monadic effect stack of a computation into arrow-based
-- effects.
--
-- NB: This is conceptually different from `ArrowKleisli`, which /inserts/ a
-- single monadic effect into an arrow-based effect stack.
--
-- NB: This is conceptually different from `ArrowApply`, which expresses that a
-- given `Arrow` /is/ a Kleisli arrow.  `ArrowInterpret` has no such condition
-- on @arr@.
class ArrowInterpret m arr where
  interpA :: arr (m a) a

instance Arrow arr => ArrowInterpret Identity arr where
  interpA = arr runIdentity

instance (ArrowInterpret m arr, ArrowWriter w arr) => ArrowInterpret (WriterT w m) arr where
  interpA = proc m -> do
    (a, w) <- interpA -< runWriterT m
    tellA -< w
    returnA -< a

instance (ArrowInterpret m arr, ArrowReader r arr) => ArrowInterpret (ReaderT r m) arr where
  interpA = proc m -> do
    r <- askA -< ()
    interpA -< runReaderT m r

instance (ArrowInterpret m arr, ArrowError e arr, ArrowChoice arr) => ArrowInterpret (ExceptT e m) arr where
  interpA = proc m -> do
    o <- interpA -< runExceptT m
    case o of
      Left e -> throwA -< e
      Right a -> returnA -< a
