{-# LANGUAGE Arrows #-}
{-# LANGUAGE UndecidableInstances #-}

module Hasura.SQL.AnyBackend
  ( AnyBackend,
    liftTag,
    mkAnyBackend,
    mapBackend,
    traverseBackend,
    dispatchAnyBackend,
    dispatchAnyBackend',
    dispatchAnyBackendArrow,
    dispatchAnyBackendWithTwoConstraints,
    unpackAnyBackend,
    composeAnyBackend,
    runBackend,
    parseAnyBackendFromJSON,
    debugAnyBackendToJSON,
  )
where

import Control.Arrow.Extended (ArrowChoice, arr, (|||))
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Kind (Constraint, Type)
import Hasura.Incremental (Cacheable)
import Hasura.Prelude
import Hasura.SQL.Backend
import Hasura.SQL.TH
import Hasura.SQL.Tag
import Language.Haskell.TH hiding (Type)

--------------------------------------------------------------------------------
-- Types and constraints

-- | This type is essentially an unlabeled box for types indexed by BackendType.
-- Given some type defined as 'data T (b :: BackendType) = ...', we can define
-- 'AnyBackend T' without mentioning any 'BackendType'.
--
-- This is useful for having generic containers of potentially different types
-- of T. For instance, @SourceCache@ is defined as a
-- @HashMap SourceName (AnyBackend SourceInfo)@.
--
-- This type is generated with Template Haskell to have one constructor per
-- backend. This declaration generates the following type:
--
--   data AnyBackend (i :: BackendType -> Type)
--     = PostgresVanillaValue (i '(Postgres Vanilla))
--     | PostgresCitusValue (i '(Postgres Citus))
--     | BigQueryValue (i 'BigQuery)
--     | MySQLValue (i 'MySQL)
--     | MSSQLValue (i 'MSSQL)
--     | ExperimentalValue (i 'Experimental)
$( do
     -- the kind of the type variable, expressed with a quote
     varKind <- [t|BackendType -> Type|]
     -- how to build a basic type: no UNPACK, no strict!, just a name
     let normalType = (Bang NoSourceUnpackedness NoSourceStrictness,)
     -- the name of the type variable
     let typeVarName = mkName "i"
     backendData
       -- the name of the type
       (mkName "AnyBackend")
       -- the type variable
       [KindedTV typeVarName varKind]
       -- the constructor for each backend
       ( \b ->
           pure $
             NormalC
               -- the name of the constructor: `FooValue`
               (getBackendValueName b)
               -- one argument: `i 'Foo`
               -- (we Apply a type Variable to a Promoted name)
               [normalType $ AppT (VarT typeVarName) (getBackendTypeValue b)]
       )
       -- classes in the deriving clause
       [''Generic]
 )

-- | Generates a constraint for all backends.
-- This Template Haskell expression generates the following constraint type:
--
--   type AllBackendsSatisfy (c :: BackendType -> Constraint) =
--     ( c 'Postgres
--     , c 'MSSQL
--     , ...
--     )
--
-- That is, given a class C, this creates the constraint that dictates that all
-- backend must satisfy C.
type AllBackendsSatisfy (c :: BackendType -> Constraint) =
  $( do
       -- the constraint for each backend: `c 'Foo`
       -- (we Apply a type Variable to a Promoted name)
       constraints <- forEachBackend \b ->
         pure $ AppT (VarT $ mkName "c") (getBackendTypeValue b)
       -- transforms a list of constraints into a tuple of constraints
       -- by folding the "type application" constructor:
       --
       --   > apply (,,)         [c 'Foo, c 'Bar, c 'Baz]
       --   > apply (c 'Foo,,)           [c 'Bar, c 'Baz]
       --   > apply (c 'Foo, c 'Bar,)            [c 'Baz]
       --   > apply (c 'Foo, c 'Bar, c 'Baz)           []
       --   = (c 'Foo, c 'Bar, c 'Baz)
       let tupleConstructor = TupleT $ length constraints
       pure $ foldl AppT tupleConstructor constraints
   )

-- | Generates a constraint for a generic type over all backends.
-- This Template Haskell expression generates the following constraint type:
--
--   type SatisfiesForAllBackends
--     (i :: BackendType -> Type)
--     (c :: Type -> Constraint)
--     = ( c (i 'Postgres)
--       , c (i 'MSSQL)
--       , ...
--       )
--
-- That is, given a type I and a class C, this creates the constraint that
-- dictates that for all backends b, @I b@ must satisfy C.
type SatisfiesForAllBackends
  (i :: BackendType -> Type)
  (c :: Type -> Constraint) =
  $( do
       -- the constraint for each backend: `c (i 'Foo)`
       constraints <- forEachBackend \b ->
         pure $ AppT (VarT $ mkName "c") $ AppT (VarT $ mkName "i") (getBackendTypeValue b)
       -- transforms a list of constraints into a tuple of constraints
       -- by folding the type application constructor
       -- by folding the "type application" constructor:
       --
       --   > apply (,,)                [c (i 'Foo), c (i 'Bar), c (i 'Baz)]
       --   > apply (c (i 'Foo),,)                  [c (i 'Bar), c (i 'Baz)]
       --   > apply (c (i 'Foo), c (i 'Bar),)                   [c (i 'Baz)]
       --   > apply (c (i 'Foo), c (i 'Bar), c (i 'Baz))                  []
       --   = (c (i 'Foo), c (i 'Bar), c (i 'Baz))
       let tupleConstructor = TupleT $ length constraints
       pure $ foldl AppT tupleConstructor constraints
   )

--------------------------------------------------------------------------------
-- Functions on AnyBackend

-- | How to obtain a tag from a runtime value. This function is generated with
-- Template Haskell for each 'Backend'. The case switch looks like this:
--
--   Postgres -> PostgresValue PostgresTag
--   MSSQL    -> MSSQLValue    MSSQLTag
--   ...
liftTag :: BackendType -> AnyBackend BackendTag
liftTag t =
  $( backendCase
       -- the expression on which we do the case switch
       [|t|]
       -- the pattern for a given backend: the backend type itself
       (\(con :| args) -> pure $ ConP con [ConP a [] | a <- args])
       -- the body for a given backend: creating and wrapping the tag
       (\b -> [|$(pure $ ConE $ getBackendValueName b) $(pure $ ConE $ getBackendTagName b)|])
       -- no default case: every constructor should be handled
       Nothing
   )

-- | Transforms an `AnyBackend i` into an `AnyBackend j`.
mapBackend ::
  forall
    (i :: BackendType -> Type)
    (j :: BackendType -> Type).
  AnyBackend i ->
  (forall b. i b -> j b) ->
  AnyBackend j
mapBackend e f =
  -- generates a case switch that, for each constructor, applies the provided function
  --   case e of
  --     FooValue x -> FooValue (f x)
  --     BarValue x -> BarValue (f x)
  $( do
       -- we create a case match for each backend
       matches <- forEachBackend \b -> do
         -- the name of the constructor
         let consName = getBackendValueName b
         -- the patterrn we match: `FooValue x`
         let matchPattern = ConP consName [VarP $ mkName "x"]
         -- the body of the match: `FooValue (f x)`
         matchBody <- [|$(pure $ ConE consName) (f x)|]
         pure $ Match matchPattern (NormalB matchBody) []
       -- the expression on which we do the case
       caseExpr <- [|e|]
       -- return the the expression of the case switch
       pure $ CaseE caseExpr matches
   )

-- | Traverse an `AnyBackend i` into an `f (AnyBackend j)`.
traverseBackend ::
  forall
    (c :: BackendType -> Constraint)
    (i :: BackendType -> Type)
    (j :: BackendType -> Type)
    f.
  (AllBackendsSatisfy c, Applicative f) =>
  AnyBackend i ->
  (forall b. c b => i b -> f (j b)) ->
  f (AnyBackend j)
traverseBackend e f =
  -- generates a case switch that, for each constructor, applies the provided function
  --   case e of
  --     FooValue x -> FooValue <$> f x
  --     BarValue x -> BarValue <$> f x
  $( do
       -- we create a case match for each backend
       matches <- forEachBackend \b -> do
         -- the name of the constructor
         let consName = getBackendValueName b
         -- the patterrn we match: `FooValue x`
         let matchPattern = ConP consName [VarP $ mkName "x"]
         -- the body of the match: `FooValue <$> f x`
         matchBody <- [|$(pure $ ConE consName) <$> f x|]
         pure $ Match matchPattern (NormalB matchBody) []
       -- the expression on which we do the case
       caseExpr <- [|e|]
       -- return the the expression of the case switch
       pure $ CaseE caseExpr matches
   )

-- | Creates a new @AnyBackend i@ for a given backend @b@ by wrapping the given @i b@.
mkAnyBackend ::
  forall
    (b :: BackendType)
    (i :: BackendType -> Type).
  HasTag b =>
  i b ->
  AnyBackend i
mkAnyBackend =
  -- generates a case switch that associates a tag constructor to a value constructor
  --   case backendTag @b of
  --     FooTag -> FooValue
  --     BarTag -> BarValue
  $( backendCase
       [|backendTag @b|]
       -- the pattern for a backend
       (\b -> pure $ ConP (getBackendTagName b) [])
       -- the body for a backend
       (pure . ConE . getBackendValueName)
       -- no default case
       Nothing
   )

-- | Dispatch a function to the value inside the @AnyBackend@, that does not
-- require bringing into scope a new class constraint.
runBackend ::
  forall
    (i :: BackendType -> Type)
    (r :: Type).
  AnyBackend i ->
  (forall (b :: BackendType). i b -> r) ->
  r
runBackend b f = $(mkDispatch 'f 'b)

-- | Dispatch an existential using an universally quantified function while
-- also resolving a different constraint.
-- Use this to dispatch Backend* instances.
-- This is essentially a wrapper around 'runAnyBackend f . repackAnyBackend @c'.
dispatchAnyBackend ::
  forall
    (c :: BackendType -> Constraint)
    (i :: BackendType -> Type)
    (r :: Type).
  AllBackendsSatisfy c =>
  AnyBackend i ->
  (forall (b :: BackendType). c b => i b -> r) ->
  r
dispatchAnyBackend e f = $(mkDispatch 'f 'e)

dispatchAnyBackendWithTwoConstraints ::
  forall
    (c1 :: BackendType -> Constraint)
    (c2 :: BackendType -> Constraint)
    (i :: BackendType -> Type)
    (r :: Type).
  AllBackendsSatisfy c1 =>
  AllBackendsSatisfy c2 =>
  AnyBackend i ->
  (forall (b :: BackendType). c1 b => c2 b => i b -> r) ->
  r
dispatchAnyBackendWithTwoConstraints e f = $(mkDispatch 'f 'e)

-- | Unlike 'dispatchAnyBackend', the expected constraint has a different kind.
-- Use for classes like 'Show', 'ToJSON', etc.
dispatchAnyBackend' ::
  forall
    (c :: Type -> Constraint)
    (i :: BackendType -> Type)
    (r :: Type).
  i `SatisfiesForAllBackends` c =>
  AnyBackend i ->
  (forall (b :: BackendType). c (i b) => i b -> r) ->
  r
dispatchAnyBackend' e f = $(mkDispatch 'f 'e)

-- | Sometimes we need to run operations on two backends of the same type.
-- If the backends don't contain the same type, the given 'r' value is returned.
-- Otherwise, the function is called with the two wrapped values.
composeAnyBackend ::
  forall
    (c :: BackendType -> Constraint)
    (i :: BackendType -> Type)
    (r :: Type).
  AllBackendsSatisfy c =>
  (forall (b :: BackendType). c b => i b -> i b -> r) ->
  AnyBackend i ->
  AnyBackend i ->
  r ->
  r
composeAnyBackend f e1 e2 owise =
  -- generates the following case expression for all backends:
  --   (FooValue a, FooValue b) -> f a b
  --   (BarValue a, BarValue b) -> f a b
  --   ...
  --   _ -> owise
  $( backendCase
       [|(e1, e2)|]
       -- the pattern for a given backend: `(FooValue a, FooValue b)`
       ( \b -> do
           let valueCon n = pure $ ConP (getBackendValueName b) [VarP $ mkName n]
           [p|($(valueCon "a"), $(valueCon "b"))|]
       )
       -- the body for each backend: `f a b`
       (const [|f a b|])
       -- the default case
       (Just [|owise|])
   )

-- | Try to unpack the type of an existential.
-- Returns @Just x@ upon a succesful match, @Nothing@ otherwise.
unpackAnyBackend ::
  forall
    (b :: BackendType)
    (i :: BackendType -> Type).
  HasTag b =>
  AnyBackend i ->
  Maybe (i b)
unpackAnyBackend exists =
  -- generates the following case expression for all backends:
  --   (FooTag, FooValue a) -> Just a
  --   ...
  --   _ -> Nothing
  $( backendCase
       [|(backendTag @b, exists)|]
       -- the pattern for a given backend
       ( \b -> do
           let tagConstructor = pure $ ConP (getBackendTagName b) []
               valConstructor = pure $ ConP (getBackendValueName b) [VarP $ mkName "a"]
           [p|($tagConstructor, $valConstructor)|]
       )
       -- the body for each backend
       (const [|Just a|])
       -- the default case
       (Just [|Nothing|])
   )

--------------------------------------------------------------------------------
-- Special case for arrows

-- Sadly, we CAN'T mix template haskell and arrow syntax... Meaning we can't
-- generate a `backendCase` within proc syntax. What we have to do instead is to
-- MANUALLY DESUGAR the arrow code, to manually construct the following
-- pipeline.
--
-- ┌────────────┐         ┌────────────────────┐                ┌───┐
-- │ AnyBackend ├─┬──────►│ Left PostgresValue ├───────────────►│ f ├────────┐
-- └────────────┘ │       └────────────────────┘                └───┘        │
--                │                                                          │
--                │       ┌─────────────────────────┐           ┌───┐        │
--                └─┬────►│ Right (Left MSSQLValue) ├──────────►│ f ├─────┐  │
--                  │     └─────────────────────────┘           └───┘     │  │
--                  │                                                     │  │
--                  │     ┌─────────────────────────────────┐   ┌───┐     │  │
--                  └─┬──►│ Right (Right (Left MongoValue)) ├───┤ f ├──┐  │  │
--                    │   └─────────────────────────────────┘   └───┘  │  │  │
--                    │                                                │  │  │
--                    │   ┌───────────────────────────┐         ┌───┐  │  │  │  ┌───┐
--                    └──►│ Right (Right (Right ...)) ├─────────┤ f ├──┴──┴──┴─►│ r │
--                        └───────────────────────────┘         └───┘           └───┘
--
-- This is what, internally, GHC would translate an arrow case-switch into: the
-- only tool it has is:
--   (|||) :: a b d -> a c d -> a (Either b c) d
--
-- It must therefore encode the case switch as an arrow from the original value
-- to this tree of Either, and then coalesce them using (|||). This is what we
-- do here.

-- | First, we create a type to represent our complicated Either type. We use
-- `Void` as a terminating case for our recursion. This declaration creates the
-- following type:
--
--   type BackendChoice (i :: BackendType -> Type)
--     = Either (i 'Postgres)
--       ( Either (i 'MSSQL)
--         ( Either ...
--            Void
type BackendChoice (i :: BackendType -> Type) =
  $( do
       -- creates the type (i b) for each backend b
       types <- forEachBackend \b ->
         pure $ AppT (VarT $ mkName "i") (getBackendTypeValue b)
       -- generate the either type by folding over that list
       let appEither l r = [t|Either $(pure l) $(pure r)|]
       foldrM appEither (ConT ''Void) types
   )

-- | Spread a 'AnyBackend' into  a 'BackendChoice'.
--
-- Given backends Foo, Bar, Baz, the type of `BackendChoice c` will be:
--   ( Either (c 'Foo)
--     ( Either (c 'Bar)
--       ( Either (c 'Baz)
--         Void )))
--
-- Accordingly, the following Template Haskell splice generates the following code:
--
--   case e of
--     FooValue x -> Left x
--     BarValue x -> Right (Left x)
--     BazValue x -> Right (Right (Left x))
spreadChoice ::
  forall
    (i :: BackendType -> Type)
    (arr :: Type -> Type -> Type).
  (ArrowChoice arr) =>
  arr (AnyBackend i) (BackendChoice i)
spreadChoice = arr $ \e ->
  $( do
       -- to each backend we match a 'BackendChoice' constructor
       -- in order: Left, Right . Left, Right . Right . Left...
       let choiceCons = iterate (UInfixE (ConE 'Right) (VarE '(.))) (ConE 'Left)
       backendCons <- backendConstructors
       -- we then construct the case match for each of them
       matches <- for (zip backendCons choiceCons) \(b, c) -> do
         -- name of the constructor: FooValue
         let consName = getBackendValueName b
         -- pattern of the match: `FooValue x`
         let matchPattern = ConP consName [VarP $ mkName "x"]
         -- expression of the match: applying the 'BackendChoice' constructor to x
         matchBody <- [|$(pure c) x|]
         pure $ Match matchPattern (NormalB matchBody) []
       -- the expression on which we do the case
       caseExpr <- [|e|]
       -- we return the case expression
       pure $ CaseE caseExpr matches
   )

-- | Coalesce a 'BackendChoice' into a result, given an arrow from each
-- possibilty to a common result.
--
-- Given backends Foo, Bar, Baz, the type of `BackendChoice c` will be:
--   ( Either (c 'Foo)
--     ( Either (c 'Bar)
--       ( Either (c 'Baz)
--         Void )))
--
-- Accordingly, the following Template Haskell splice generates the following code:
--
--   ( arrow |||
--     ( arrow |||
--       ( arrow |||
--         absurd )))
coalesceChoice ::
  forall
    (c1 :: BackendType -> Constraint)
    (c2 :: BackendType -> Constraint)
    (i :: BackendType -> Type)
    (r :: Type)
    (arr :: Type -> Type -> Type).
  (ArrowChoice arr, AllBackendsSatisfy c1, AllBackendsSatisfy c2) =>
  (forall b. c1 b => c2 b => arr (i b) r) ->
  arr (BackendChoice i) r
coalesceChoice arrow =
  $( do
       -- associate the arrow to each type
       arrows <- forEachBackend $ const [|arrow|]
       -- the default case of our fold is `arr absurd` for the terminating Void
       baseCase <- [|arr absurd|]
       -- how to combine two arrows using (|||)
       let combine = \l r -> [|$(pure l) ||| $(pure r)|]
       foldrM combine baseCase arrows
   )

-- | Dispatch variant for use with arrow syntax. The universally quantified
-- dispatch function is an arrow instead. Since we can't express this using
-- Template Haskell, we instead generate the arrow by combining `spreadChoice`
-- and `coalesceChoice`.
dispatchAnyBackendArrow' ::
  forall
    (c1 :: BackendType -> Constraint)
    (c2 :: BackendType -> Constraint)
    (i :: BackendType -> Type)
    (r :: Type)
    (arr :: Type -> Type -> Type).
  (ArrowChoice arr, AllBackendsSatisfy c1, AllBackendsSatisfy c2) =>
  (forall b. c1 b => c2 b => arr (i b) r) ->
  arr (AnyBackend i) r
dispatchAnyBackendArrow' arrow = spreadChoice >>> coalesceChoice @c1 @c2 arrow

-- | While dispatchAnyBackendArrow' is expressed over an `AnyBackend`, in
-- practice we need slightly more complex types. Specifically: the only call
-- site for 'dispatchAnyBackendArrow' uses a four element tuple containing an
-- 'AnyBackend'.
newtype BackendArrowTuple x i (b :: BackendType) = BackendArrowTuple {unTuple :: (i b, x)}

-- | Finally, we can do the dispatch on the four-elements tuple.
-- Here's what happens, step by step:
--
-- ┌─────────────────────────┐
-- │ (x, y, AnyBackend i, z) │
-- └─┬───────────────────────┘
--   │
--   │   cons
--   ▼
-- ┌────────────────────────────────────────┐                 ┌─────────────────────────────┐
-- │ AnyBackend (BackendArrowTuple x y z i) │          ┌───►  │ BackendArrowTuple x y z i b │
-- └─┬──────────────────────────────────────┘          │      └─┬───────────────────────────┘
--   │                                                 │        │
--   │   spreadChoice                                  │        │   arr unTuple
--   ▼                                                 │        ▼
-- ┌───────────────────────────────────────────┐       │      ┌────────────────┐
-- │ BackendChoice (BackendArrowTuple x y z i) │       │      │ (x, y, i b, z) │
-- └─┬─────────────────────────────────────────┘       │      └─┬──────────────┘
--   │                                                 │        │
--   │   coalesceChoice (arr unTuple >>> arrow)  ◄─────┘        │   arrow
--   ▼                                                          ▼
-- ┌───┐                                                      ┌───┐
-- │ r │                                                      │ r │
-- └───┘                                                      └───┘
--
-- NOTE: The below function accepts two constraints, if the arrow
-- you want to dispatch only has one constraint then repeat the constraint twice.
-- For example:
-- ```AB.dispatchAnyBackendArrow @BackendMetadata @BackendMetadata (proc (sourceMetadata, invalidationKeys)```
dispatchAnyBackendArrow ::
  forall
    (c1 :: BackendType -> Constraint)
    (c2 :: BackendType -> Constraint)
    (i :: BackendType -> Type)
    (r :: Type)
    (arr :: Type -> Type -> Type)
    x.
  (ArrowChoice arr, AllBackendsSatisfy c1, AllBackendsSatisfy c2) =>
  (forall b. c1 b => c2 b => arr (i b, x) r) ->
  arr (AnyBackend i, x) r
dispatchAnyBackendArrow arrow =
  arr cons >>> dispatchAnyBackendArrow' @c1 @c2 (arr unTuple >>> arrow)
  where
    cons :: (AnyBackend i, x) -> AnyBackend (BackendArrowTuple x i)
    cons (e, x) = mapBackend e \ib -> BackendArrowTuple (ib, x)

--------------------------------------------------------------------------------
-- JSON functions

-- | Attempts to parse an 'AnyBackend' from a JSON value, using the provided
-- backend information.
parseAnyBackendFromJSON ::
  i `SatisfiesForAllBackends` FromJSON =>
  BackendType ->
  Value ->
  Parser (AnyBackend i)
parseAnyBackendFromJSON backendKind value = do
  -- generates the following case for all backends:
  --   Foo -> FooValue <$> parseJSON value
  --   Bar -> BarValue <$> parseJSON value
  --   ...
  $( backendCase
       [|backendKind|]
       -- the pattern for a given backend
       (\(con :| args) -> pure $ ConP con [ConP arg [] | arg <- args])
       -- the body for each backend
       ( \b -> do
           let valueCon = pure $ ConE $ getBackendValueName b
           [|$valueCon <$> parseJSON value|]
       )
       -- no default case
       Nothing
   )

-- | Outputs a debug JSON value from an 'AnyBackend'. This function must only be
-- used for debug purposes, as it has no way of inserting the backend kind in
-- the output, since there's no guarantee that the output will be an object.
debugAnyBackendToJSON ::
  i `SatisfiesForAllBackends` ToJSON =>
  AnyBackend i ->
  Value
debugAnyBackendToJSON e = dispatchAnyBackend' @ToJSON e toJSON

--------------------------------------------------------------------------------
-- Instances for 'AnyBackend'

deriving instance i `SatisfiesForAllBackends` Show => Show (AnyBackend i)

deriving instance i `SatisfiesForAllBackends` Eq => Eq (AnyBackend i)

instance i `SatisfiesForAllBackends` Hashable => Hashable (AnyBackend i)

instance i `SatisfiesForAllBackends` Cacheable => Cacheable (AnyBackend i)
