{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE UndecidableInstances #-}

-- | This modules defines the tree of Select types: how we represent a query internally, from its top
--   level 'QueryDB' down to each individual field. Most of those types have three type arguments:
--
--   b: BackendType
--     The backend that is targeted by that specific select (Postgres Vanilla, MSSQL...); we use the
--     type families in the Backend class to decide how different parts of the IR are represented in
--     different backends.
--
--   v: Type
--     The type of the leaf values in our AST; used almost exclusively for column values, over which
--     queries can be parameterized. The output of the parser phase will use @UnpreparedValue b@ for
--     the leaves, and most backends will then transform the AST to interpret those values and
--     consequently change @v@ to be @SQLExpression b@
--
--   r: BackendType -> Type
--     Joins across backends mean that the aforementioned @b@ parameter won't be the same throughout
--     the entire tree; at some point we will have an 'AnyBackend' used to encapsulate a branch that
--     uses a different @b@. We still want, however, to be able to parameterize the values of the
--     leaves in that separate branch, and that's what the @r@ parameter is for. We also use
--     'UnpreparedValue' here during the parsing phase, meaning all leaf values will be
--     @UnpreparedValue b@ for their respective backend @b@, and most backends will then transform
--     their AST, cutting all such remote branches, and therefore using @Const Void@ for @r@.
module Hasura.RQL.IR.Select
  ( AggregateField (..),
    AggregateFields,
    AggregateOp (..),
    AnnAggregateSelect,
    AnnAggregateSelectG,
    AnnColumnField (..),
    AnnField,
    AnnFieldG (..),
    AnnFields,
    AnnFieldsG,
    AnnObjectSelect,
    AnnObjectSelectG (..),
    AnnRelationSelectG (..),
    AnnSelectG (..),
    AnnSimpleSelect,
    AnnSimpleSelectG,
    AnnotatedAggregateOrderBy (..),
    AnnotatedOrderByElement (..),
    AnnotatedOrderByItem,
    AnnotatedOrderByItemG,
    ArgumentExp (..),
    ArrayAggregateSelect,
    ArrayAggregateSelectG,
    ArrayConnectionSelect,
    ArrayRelationSelectG,
    ArraySelect,
    ArraySelectFieldsG,
    ArraySelectG (..),
    ColFld (..),
    ColumnFields,
    ColumnOp (..),
    ComputedFieldOrderBy (..),
    ComputedFieldOrderByElement (..),
    ComputedFieldScalarSelect (..),
    ComputedFieldSelect (..),
    ConnectionField (..),
    ConnectionFields,
    ConnectionSelect (..),
    ConnectionSlice (..),
    ConnectionSplit (..),
    ConnectionSplitKind (..),
    EdgeField (..),
    EdgeFields,
    FunctionArgExp,
    FunctionArgsExpG (..),
    FunctionArgsExpTableRow,
    FIIdentifier (..),
    ObjectRelationSelect,
    ObjectRelationSelectG,
    PageInfoField (..),
    PageInfoFields,
    QueryDB (..),
    RemoteSourceSelect (..),
    SelectArgs,
    SelectArgsG (..),
    SelectFrom,
    SelectFromG (..),
    RemoteRelationshipSelect (..),
    SourceRelationshipSelection (..),
    TableAggregateField,
    TableAggregateFieldG (..),
    TableAggregateFields,
    TableAggregateFieldsG,
    TablePerm,
    TablePermG (..),
    CountDistinct (..),
    actionResponsePayloadColumn,
    aarRelationshipName,
    aarColumnMapping,
    aarAnnSelect,
    aosFields,
    aosTableFrom,
    aosTableFilter,
    asnArgs,
    asnFields,
    asnFrom,
    asnPerm,
    asnStrfyNum,
    bifoldMapAnnSelectG,
    csXRelay,
    csPrimaryKeyColumns,
    csSplit,
    csSlice,
    csSelect,
    emptyFunctionArgsExp,
    functionArgsWithTableRowAndSession,
    insertFunctionArg,
    mkAnnColumnField,
    mkAnnColumnFieldAsText,
    noSelectArgs,
    noTablePermissions,
    onArgumentExp,
    saDistinct,
    saLimit,
    saOffset,
    saOrderBy,
    saWhere,
    _AFArrayRelation,
    _AFColumn,
    _AFComputedField,
    _AFExpression,
    _AFNodeId,
    _AFObjectRelation,
    _AFRemote,
    _AOCArrayAggregation,
    _AOCColumn,
    _AOCComputedField,
    _AOCObjectRelation,
    _TAFAgg,
    _TAFNodes,
    _TAFExp,
    _ConnectionTypename,
    _ConnectionPageInfo,
    _ConnectionEdges,
    _EdgeTypename,
    _EdgeCursor,
    _EdgeNode,
  )
where

import Control.Lens.TH (makeLenses, makePrisms)
import Data.Bifoldable
import Data.HashMap.Strict qualified as HM
import Data.Int (Int64)
import Data.Kind (Type)
import Data.List.NonEmpty qualified as NE
import Data.Sequence qualified as Seq
import Hasura.Backends.Postgres.SQL.Types qualified as PG
import Hasura.Prelude
import Hasura.RQL.IR.BoolExp
import Hasura.RQL.IR.OrderBy
import Hasura.RQL.Types.Backend
import Hasura.RQL.Types.Column
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.ComputedField
import Hasura.RQL.Types.Function
import Hasura.RQL.Types.Instances ()
import Hasura.RQL.Types.Relationships.Local
import Hasura.RQL.Types.Relationships.Remote
import Hasura.SQL.Backend

-- Root selection

data QueryDB (b :: BackendType) (r :: Type) v
  = QDBMultipleRows (AnnSimpleSelectG b r v)
  | QDBSingleRow (AnnSimpleSelectG b r v)
  | QDBAggregation (AnnAggregateSelectG b r v)
  | QDBConnection (ConnectionSelect b r v)
  deriving stock (Generic, Functor, Foldable, Traversable)

instance Backend b => Bifoldable (QueryDB b) where
  bifoldMap f g = \case
    QDBMultipleRows annSel -> bifoldMapAnnSelectG f g annSel
    QDBSingleRow annSel -> bifoldMapAnnSelectG f g annSel
    QDBAggregation annSel -> bifoldMapAnnSelectG f g annSel
    QDBConnection connSel -> bifoldMap f g connSel

-- Select

data AnnSelectG (b :: BackendType) (f :: Type -> Type) (v :: Type) = AnnSelectG
  { _asnFields :: Fields (f v),
    _asnFrom :: SelectFromG b v,
    _asnPerm :: TablePermG b v,
    _asnArgs :: SelectArgsG b v,
    _asnStrfyNum :: StringifyNumbers
  }
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v,
    Eq (f v)
  ) =>
  Eq (AnnSelectG b f v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v,
    Show (f v)
  ) =>
  Show (AnnSelectG b f v)

type AnnSimpleSelectG b r v = AnnSelectG b (AnnFieldG b r) v

type AnnAggregateSelectG b r v = AnnSelectG b (TableAggregateFieldG b r) v

type AnnSimpleSelect b = AnnSimpleSelectG b Void (SQLExpression b)

type AnnAggregateSelect b = AnnAggregateSelectG b Void (SQLExpression b)

-- | We can't write a Bifoldable instance for AnnSelectG because the types don't line up.
-- Instead, we provide this function which can be used to help define Bifoldable instances of other types
-- containing AnnSelectG values.
bifoldMapAnnSelectG :: (Backend b, Bifoldable (f b), Monoid m) => (r -> m) -> (v -> m) -> AnnSelectG b (f b r) v -> m
bifoldMapAnnSelectG f g AnnSelectG {..} =
  foldMap (foldMap $ bifoldMap f g) _asnFields
    <> foldMap g _asnFrom
    <> foldMap g _asnPerm
    <> foldMap g _asnArgs

-- Relay select

data ConnectionSelect (b :: BackendType) (r :: Type) v = ConnectionSelect
  { _csXRelay :: XRelay b,
    _csPrimaryKeyColumns :: PrimaryKeyColumns b,
    _csSplit :: Maybe (NE.NonEmpty (ConnectionSplit b v)),
    _csSlice :: Maybe ConnectionSlice,
    _csSelect :: (AnnSelectG b (ConnectionField b r) v)
  }
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v,
    Eq r
  ) =>
  Eq (ConnectionSelect b r v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v,
    Show r
  ) =>
  Show (ConnectionSelect b r v)

instance Backend b => Bifoldable (ConnectionSelect b) where
  bifoldMap f g ConnectionSelect {..} =
    foldMap (foldMap $ foldMap g) _csSplit
      <> bifoldMapAnnSelectG f g _csSelect

data ConnectionSplit (b :: BackendType) v = ConnectionSplit
  { _csKind :: ConnectionSplitKind,
    _csValue :: v,
    _csOrderBy :: (OrderByItemG b (AnnotatedOrderByElement b v))
  }
  deriving stock (Functor, Generic, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq v,
    Eq (BooleanOperators b v)
  ) =>
  Eq (ConnectionSplit b v)

deriving stock instance
  ( Backend b,
    Show v,
    Show (BooleanOperators b v)
  ) =>
  Show (ConnectionSplit b v)

instance
  ( Backend b,
    Hashable (BooleanOperators b v),
    Hashable (ColumnInfo b),
    Hashable v
  ) =>
  Hashable (ConnectionSplit b v)

data ConnectionSlice
  = SliceFirst Int
  | SliceLast Int
  deriving stock (Show, Eq, Generic)
  deriving anyclass (Hashable)

data ConnectionSplitKind
  = CSKBefore
  | CSKAfter
  deriving stock (Show, Eq, Generic)
  deriving anyclass (Hashable)

-- From

-- | Identifier used exclusively as the argument to 'FromIdentifier'
newtype FIIdentifier = FIIdentifier
  { unFIIdentifier :: Text
  }
  deriving stock (Generic)
  deriving newtype (Eq, Show)
  deriving anyclass (Hashable)

instance PG.IsIdentifier FIIdentifier where
  toIdentifier = coerce
  {-# INLINE toIdentifier #-}

data SelectFromG (b :: BackendType) v
  = FromTable (TableName b)
  | FromIdentifier FIIdentifier
  | FromFunction
      (FunctionName b)
      (FunctionArgsExpTableRow v)
      -- a definition list
      (Maybe [(Column b, ScalarType b)])
  deriving stock (Functor, Foldable, Traversable, Generic)

deriving stock instance (Backend b, Eq v) => Eq (SelectFromG b v)

deriving stock instance (Backend b, Show v) => Show (SelectFromG b v)

instance (Backend b, Hashable v) => Hashable (SelectFromG b v)

type SelectFrom b = SelectFromG b (SQLExpression b)

-- Select arguments

data SelectArgsG (b :: BackendType) v = SelectArgs
  { _saWhere :: Maybe (AnnBoolExp b v),
    _saOrderBy :: Maybe (NE.NonEmpty (AnnotatedOrderByItemG b v)),
    _saLimit :: Maybe Int,
    _saOffset :: Maybe Int64,
    _saDistinct :: (Maybe (NE.NonEmpty (Column b)))
  }
  deriving stock (Generic, Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v
  ) =>
  Eq (SelectArgsG b v)

instance
  ( Backend b,
    Hashable (BooleanOperators b v),
    Hashable v
  ) =>
  Hashable (SelectArgsG b v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v
  ) =>
  Show (SelectArgsG b v)

type SelectArgs b = SelectArgsG b (SQLExpression b)

noSelectArgs :: SelectArgsG backend v
noSelectArgs = SelectArgs Nothing Nothing Nothing Nothing Nothing

-- Order by argument

-- | The order by element for a computed field based on its return type
data ComputedFieldOrderByElement (b :: BackendType) v
  = -- | Sort by the scalar computed field
    CFOBEScalar (ScalarType b)
  | CFOBETableAggregation
      (TableName b)
      (AnnBoolExp b v)
      -- ^ Permission filter of the retuning table
      (AnnotatedAggregateOrderBy b)
      -- ^ Sort by aggregation fields of table rows returned by computed field
  deriving stock (Generic, Functor, Foldable, Traversable)

deriving stock instance (Backend b, Eq v, Eq (BooleanOperators b v)) => Eq (ComputedFieldOrderByElement b v)

deriving stock instance (Backend b, Show v, Show (BooleanOperators b v)) => Show (ComputedFieldOrderByElement b v)

instance (Backend b, Hashable v, Hashable (BooleanOperators b v)) => Hashable (ComputedFieldOrderByElement b v)

data ComputedFieldOrderBy (b :: BackendType) v = ComputedFieldOrderBy
  { _cfobXField :: XComputedField b,
    _cfobName :: ComputedFieldName,
    _cfobFunction :: FunctionName b,
    _cfobFunctionArgsExp :: FunctionArgsExpTableRow v,
    _cfobOrderByElement :: (ComputedFieldOrderByElement b v)
  }
  deriving stock (Generic, Functor, Foldable, Traversable)

deriving stock instance (Backend b, Eq v, Eq (BooleanOperators b v)) => Eq (ComputedFieldOrderBy b v)

deriving stock instance (Backend b, Show v, Show (BooleanOperators b v)) => Show (ComputedFieldOrderBy b v)

instance (Backend b, Hashable v, Hashable (BooleanOperators b v)) => Hashable (ComputedFieldOrderBy b v)

data AnnotatedOrderByElement (b :: BackendType) v
  = AOCColumn (ColumnInfo b)
  | AOCObjectRelation
      (RelInfo b)
      (AnnBoolExp b v)
      -- ^ Permission filter of the remote table to which the relationship is defined
      (AnnotatedOrderByElement b v)
  | AOCArrayAggregation
      (RelInfo b)
      (AnnBoolExp b v)
      -- ^ Permission filter of the remote table to which the relationship is defined
      (AnnotatedAggregateOrderBy b)
  | AOCComputedField (ComputedFieldOrderBy b v)
  deriving stock (Generic, Functor, Foldable, Traversable)

deriving stock instance (Backend b, Eq v, Eq (BooleanOperators b v)) => Eq (AnnotatedOrderByElement b v)

deriving stock instance (Backend b, Show v, Show (BooleanOperators b v)) => Show (AnnotatedOrderByElement b v)

instance (Backend b, Hashable v, Hashable (BooleanOperators b v)) => Hashable (AnnotatedOrderByElement b v)

data AnnotatedAggregateOrderBy (b :: BackendType)
  = AAOCount
  | AAOOp Text !(ColumnInfo b)
  deriving stock (Generic)

deriving stock instance (Backend b) => Eq (AnnotatedAggregateOrderBy b)

deriving stock instance (Backend b) => Show (AnnotatedAggregateOrderBy b)

instance (Backend b) => Hashable (AnnotatedAggregateOrderBy b)

type AnnotatedOrderByItemG b v = OrderByItemG b (AnnotatedOrderByElement b v)

type AnnotatedOrderByItem b = AnnotatedOrderByItemG b (SQLExpression b)

-- Fields

-- | captures a remote relationship's selection and the necessary context
data RemoteRelationshipSelect b r = RemoteRelationshipSelect
  { -- | The fields on the table that are required for the join condition
    -- of the remote relationship
    _rrsLHSJoinFields :: HashMap FieldName (DBJoinField b),
    -- | The field that captures the relationship
    -- r ~ (RemoteRelationshipField UnpreparedValue) when the AST is emitted by the parser.
    -- r ~ Void when an execution tree is constructed so that a backend is
    -- absolved of dealing with remote relationships.
    _rrsRelationship :: r
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data AnnFieldG (b :: BackendType) (r :: Type) v
  = AFColumn (AnnColumnField b v)
  | AFObjectRelation (ObjectRelationSelectG b r v)
  | AFArrayRelation (ArraySelectG b r v)
  | AFComputedField (XComputedField b) !ComputedFieldName !(ComputedFieldSelect b r v)
  | -- | A remote relationship field
    AFRemote (RemoteRelationshipSelect b r)
  | AFNodeId (XRelay b) !(TableName b) !(PrimaryKeyColumns b)
  | AFExpression Text
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v,
    Eq r
  ) =>
  Eq (AnnFieldG b r v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v,
    Show r
  ) =>
  Show (AnnFieldG b r v)

instance Backend b => Bifoldable (AnnFieldG b) where
  bifoldMap f g = \case
    AFColumn col -> foldMap g col
    AFObjectRelation objRel -> foldMap (bifoldMap f g) objRel
    AFArrayRelation arrRel -> bifoldMap f g arrRel
    AFComputedField _ _ cf -> bifoldMap f g cf
    AFRemote r -> foldMap f r
    AFNodeId {} -> mempty
    AFExpression {} -> mempty

type AnnField b = AnnFieldG b Void (SQLExpression b)

type AnnFields b = AnnFieldsG b Void (SQLExpression b)

mkAnnColumnField ::
  Column backend ->
  ColumnType backend ->
  Maybe (AnnColumnCaseBoolExp backend v) ->
  Maybe (ColumnOp backend) ->
  AnnFieldG backend r v
mkAnnColumnField col typ caseBoolExp colOpM =
  AFColumn (AnnColumnField col typ False colOpM caseBoolExp)

mkAnnColumnFieldAsText ::
  ColumnInfo backend ->
  AnnFieldG backend r v
mkAnnColumnFieldAsText ci =
  AFColumn (AnnColumnField (ciColumn ci) (ciType ci) True Nothing Nothing)

-- Aggregation fields

data TableAggregateFieldG (b :: BackendType) (r :: Type) v
  = TAFAgg (AggregateFields b)
  | TAFNodes (XNodesAgg b) (AnnFieldsG b r v)
  | TAFExp Text
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v,
    Eq r
  ) =>
  Eq (TableAggregateFieldG b r v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v,
    Show r
  ) =>
  Show (TableAggregateFieldG b r v)

instance Backend b => Bifoldable (TableAggregateFieldG b) where
  bifoldMap f g = \case
    TAFAgg {} -> mempty
    TAFNodes _ fields -> foldMap (foldMap $ bifoldMap f g) fields
    TAFExp {} -> mempty

data AggregateField (b :: BackendType)
  = AFCount (CountType b)
  | AFOp (AggregateOp b)
  | AFExp Text

deriving stock instance (Backend b) => Eq (AggregateField b)

deriving stock instance (Backend b) => Show (AggregateField b)

data AggregateOp (b :: BackendType) = AggregateOp
  { _aoOp :: Text,
    _aoFields :: (ColumnFields b)
  }
  deriving stock (Eq, Show)

data ColFld (b :: BackendType)
  = CFCol (Column b) !(ColumnType b)
  | CFExp Text
  deriving stock (Eq, Show)

type TableAggregateField b = TableAggregateFieldG b Void (SQLExpression b)

type TableAggregateFields b = TableAggregateFieldsG b Void (SQLExpression b)

type TableAggregateFieldsG b r v = Fields (TableAggregateFieldG b r v)

type ColumnFields b = Fields (ColFld b)

type AggregateFields b = Fields (AggregateField b)

type AnnFieldsG b r v = Fields (AnnFieldG b r v)

-- Relay fields

data ConnectionField (b :: BackendType) (r :: Type) v
  = ConnectionTypename Text
  | ConnectionPageInfo PageInfoFields
  | ConnectionEdges (EdgeFields b r v)
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v,
    Eq r
  ) =>
  Eq (ConnectionField b r v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v,
    Show r
  ) =>
  Show (ConnectionField b r v)

instance Backend b => Bifoldable (ConnectionField b) where
  bifoldMap f g = \case
    ConnectionTypename {} -> mempty
    ConnectionPageInfo {} -> mempty
    ConnectionEdges edgeFields -> foldMap (foldMap $ bifoldMap f g) edgeFields

data PageInfoField
  = PageInfoTypename Text
  | PageInfoHasNextPage
  | PageInfoHasPreviousPage
  | PageInfoStartCursor
  | PageInfoEndCursor
  deriving stock (Show, Eq)

data EdgeField (b :: BackendType) (r :: Type) v
  = EdgeTypename Text
  | EdgeCursor
  | EdgeNode (AnnFieldsG b r v)
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v,
    Eq r
  ) =>
  Eq (EdgeField b r v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v,
    Show r
  ) =>
  Show (EdgeField b r v)

instance Backend b => Bifoldable (EdgeField b) where
  bifoldMap f g = \case
    EdgeTypename {} -> mempty
    EdgeCursor -> mempty
    EdgeNode annFields -> foldMap (foldMap $ bifoldMap f g) annFields

type ConnectionFields b r v = Fields (ConnectionField b r v)

type PageInfoFields = Fields PageInfoField

type EdgeFields b r v = Fields (EdgeField b r v)

data AnnColumnField (b :: BackendType) v = AnnColumnField
  { _acfColumn :: Column b,
    _acfType :: ColumnType b,
    -- | If this field is 'True', columns are explicitly casted to @text@ when fetched, which avoids
    -- an issue that occurs because we don’t currently have proper support for array types. See
    -- https://github.com/hasura/graphql-engine/pull/3198 for more details.
    _acfAsText :: Bool,
    _acfOp :: Maybe (ColumnOp b),
    -- | This type is used to determine whether the column
    -- should be nullified. When the value is `Nothing`, the column value
    -- will be outputted as computed and when the value is `Just c`, the
    -- column will be outputted when `c` evaluates to `true` and `null`
    -- when `c` evaluates to `false`.
    _acfCaseBoolExpression :: (Maybe (AnnColumnCaseBoolExp b v))
  }
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v
  ) =>
  Eq (AnnColumnField b v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v
  ) =>
  Show (AnnColumnField b v)

data ColumnOp (b :: BackendType) = ColumnOp
  { _colOp :: SQLOperator b,
    _colExp :: SQLExpression b
  }

deriving stock instance Backend b => Show (ColumnOp b)

deriving stock instance Backend b => Eq (ColumnOp b)

-- Computed field

data ComputedFieldScalarSelect (b :: BackendType) v = ComputedFieldScalarSelect
  { _cfssFunction :: FunctionName b,
    _cfssArguments :: FunctionArgsExpTableRow v,
    _cfssType :: ScalarType b,
    _cfssColumnOp :: (Maybe (ColumnOp b))
  }
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance (Backend b, Show v) => Show (ComputedFieldScalarSelect b v)

deriving stock instance (Backend b, Eq v) => Eq (ComputedFieldScalarSelect b v)

data ComputedFieldSelect (b :: BackendType) (r :: Type) v
  = CFSScalar
      (ComputedFieldScalarSelect b v)
      -- ^ Type containing info about the computed field
      (Maybe (AnnColumnCaseBoolExp b v))
      -- ^ This type is used to determine if whether the scalar
      -- computed field should be nullified. When the value is `Nothing`,
      -- the scalar computed value will be outputted as computed and when the
      -- value is `Just c`, the scalar computed field will be outputted when
      -- `c` evaluates to `true` and `null` when `c` evaluates to `false`
  | CFSTable JsonAggSelect !(AnnSimpleSelectG b r v)
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v,
    Eq r
  ) =>
  Eq (ComputedFieldSelect b r v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v,
    Show r
  ) =>
  Show (ComputedFieldSelect b r v)

instance Backend b => Bifoldable (ComputedFieldSelect b) where
  bifoldMap f g = \case
    CFSScalar cfsSelect caseBoolExp -> foldMap g cfsSelect <> foldMap (foldMap $ foldMap g) caseBoolExp
    CFSTable _ simpleSelect -> bifoldMapAnnSelectG f g simpleSelect

-- Local relationship

data AnnRelationSelectG (b :: BackendType) a = AnnRelationSelectG
  { _aarRelationshipName :: RelName, -- Relationship name
    _aarColumnMapping :: HashMap (Column b) (Column b), -- Column of left table to join with
    _aarAnnSelect :: a -- Current table. Almost ~ to SQL Select
  }
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance (Backend b, Eq v) => Eq (AnnRelationSelectG b v)

deriving stock instance (Backend b, Show v) => Show (AnnRelationSelectG b v)

type ArrayRelationSelectG b r v = AnnRelationSelectG b (AnnSimpleSelectG b r v)

type ArrayAggregateSelectG b r v = AnnRelationSelectG b (AnnAggregateSelectG b r v)

type ArrayConnectionSelect b r v = AnnRelationSelectG b (ConnectionSelect b r v)

type ArrayAggregateSelect b = ArrayAggregateSelectG b Void (SQLExpression b)

data AnnObjectSelectG (b :: BackendType) (r :: Type) v = AnnObjectSelectG
  { _aosFields :: AnnFieldsG b r v,
    _aosTableFrom :: TableName b,
    _aosTableFilter :: (AnnBoolExp b v)
  }
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v,
    Eq r
  ) =>
  Eq (AnnObjectSelectG b r v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v,
    Show r
  ) =>
  Show (AnnObjectSelectG b r v)

instance Backend b => Bifoldable (AnnObjectSelectG b) where
  bifoldMap f g AnnObjectSelectG {..} =
    foldMap (foldMap $ bifoldMap f g) _aosFields <> foldMap (foldMap g) _aosTableFilter

type AnnObjectSelect b r = AnnObjectSelectG b r (SQLExpression b)

type ObjectRelationSelectG b r v = AnnRelationSelectG b (AnnObjectSelectG b r v)

type ObjectRelationSelect b = ObjectRelationSelectG b Void (SQLExpression b)

data ArraySelectG (b :: BackendType) (r :: Type) v
  = ASSimple (ArrayRelationSelectG b r v)
  | ASAggregate (ArrayAggregateSelectG b r v)
  | ASConnection (ArrayConnectionSelect b r v)
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v,
    Eq r
  ) =>
  Eq (ArraySelectG b r v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v,
    Show r
  ) =>
  Show (ArraySelectG b r v)

instance Backend b => Bifoldable (ArraySelectG b) where
  bifoldMap f g = \case
    ASSimple arrayRelationSelect -> foldMap (bifoldMapAnnSelectG f g) arrayRelationSelect
    ASAggregate arrayAggregateSelect -> foldMap (bifoldMapAnnSelectG f g) arrayAggregateSelect
    ASConnection arrayConnectionSelect -> foldMap (bifoldMap f g) arrayConnectionSelect

type ArraySelect b = ArraySelectG b Void (SQLExpression b)

type ArraySelectFieldsG b r v = Fields (ArraySelectG b r v)

-- | Captures the selection set of a remote source relationship.
data
  SourceRelationshipSelection
    (b :: BackendType)
    (r :: Type)
    (vf :: BackendType -> Type)
  = SourceRelationshipObject (AnnObjectSelectG b r (vf b))
  | SourceRelationshipArray (AnnSimpleSelectG b r (vf b))
  | SourceRelationshipArrayAggregate (AnnAggregateSelectG b r (vf b))

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b (v b)),
    Eq (v b),
    Eq r
  ) =>
  Eq (SourceRelationshipSelection b r v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b (v b)),
    Show (v b),
    Show r
  ) =>
  Show (SourceRelationshipSelection b r v)

-- | A relationship to a remote source. 'vf' (could use a better name) is
-- analogous to 'v' in other IR types such as 'AnnFieldG'. vf's kind is
-- (BackendType -> Type) instead of v's 'Type' so that 'v' of 'AnnFieldG' can
-- be specific to the backend that it captures ('b' of an AnnFieldG changes as
-- we walk down the IR branches which capture relationships to other databases)
data
  RemoteSourceSelect
    (r :: Type)
    (vf :: BackendType -> Type)
    (tgt :: BackendType) = RemoteSourceSelect
  { _rssName :: SourceName,
    _rssConfig :: SourceConfig tgt,
    _rssSelection :: SourceRelationshipSelection tgt r vf,
    -- | Additional information about the source's join columns:
    -- (ScalarType tgt) so that the remote can interpret the join values coming
    -- from src
    -- (Column tgt) so that an appropriate join condition / IN clause can be built
    -- by the remote
    _rssJoinMapping :: (HM.HashMap FieldName (ScalarType tgt, Column tgt))
  }

-- Permissions

data TablePermG (b :: BackendType) v = TablePerm
  { _tpFilter :: AnnBoolExp b v,
    _tpLimit :: (Maybe Int)
  }
  deriving stock (Generic, Functor, Foldable, Traversable)

deriving stock instance
  ( Backend b,
    Eq (BooleanOperators b v),
    Eq v
  ) =>
  Eq (TablePermG b v)

deriving stock instance
  ( Backend b,
    Show (BooleanOperators b v),
    Show v
  ) =>
  Show (TablePermG b v)

instance
  ( Backend b,
    Hashable (BooleanOperators b v),
    Hashable (ColumnInfo b),
    Hashable v
  ) =>
  Hashable (TablePermG b v)

type TablePerm b = TablePermG b (SQLExpression b)

noTablePermissions :: TablePermG backend v
noTablePermissions = TablePerm annBoolExpTrue Nothing

-- Function arguments

data ArgumentExp a
  = -- | Table row accessor
    AETableRow
  | -- | Hardcoded reference to @hdb_catalog.hdb_action_log.response_payload@
    AEActionResponsePayload
  | -- | JSON/JSONB hasura session variable object
    AESession a
  | AEInput a
  deriving stock (Eq, Show, Functor, Foldable, Traversable, Generic)
  deriving anyclass (Hashable)

-- | Eliminate 'ArgumentExp'
--
-- Used to ensure that the right column is used for 'AEActionResponsePayload'.
onArgumentExp ::
  -- | Value to return for 'AETableRow'
  a ->
  -- | Create value to return for 'AEResponsePayload' given column text
  (Text -> a) ->
  -- | 'ArgumentExp' to eliminate
  ArgumentExp a ->
  a
onArgumentExp tableRow fromColumn = \case
  AETableRow -> tableRow
  AEActionResponsePayload -> fromColumn actionResponsePayloadColumn
  AESession a -> a
  AEInput a -> a

-- | Hardcoded @hdb_catalog.hdb_action_log.response_payload@ column name
actionResponsePayloadColumn :: Text
actionResponsePayloadColumn = "response_payload"
{-# INLINE actionResponsePayloadColumn #-}

data FunctionArgsExpG a = FunctionArgsExp
  { _faePositional :: [a],
    _faeNamed :: (HM.HashMap Text a)
  }
  deriving stock (Show, Eq, Functor, Foldable, Traversable, Generic)
  deriving anyclass (Hashable)

type FunctionArgsExpTableRow v = FunctionArgsExpG (ArgumentExp v)

type FunctionArgExp b = FunctionArgsExpG (SQLExpression b)

emptyFunctionArgsExp :: FunctionArgsExpG a
emptyFunctionArgsExp = FunctionArgsExp [] HM.empty

functionArgsWithTableRowAndSession ::
  v ->
  FunctionTableArgument ->
  Maybe FunctionSessionArgument ->
  [ArgumentExp v]
functionArgsWithTableRowAndSession _ _ Nothing = [AETableRow] -- No session argument
functionArgsWithTableRowAndSession sess (FTAFirst) _ = [AETableRow, AESession sess]
functionArgsWithTableRowAndSession sess (FTANamed _ 0) _ = [AETableRow, AESession sess] -- Index is 0 implies table argument is first
functionArgsWithTableRowAndSession sess _ _ = [AESession sess, AETableRow]

-- | If argument positional index is less than or equal to length of
-- 'positional' arguments then insert the value in 'positional' arguments else
-- insert the value with argument name in 'named' arguments
insertFunctionArg ::
  FunctionArgName ->
  Int ->
  a ->
  FunctionArgsExpG a ->
  FunctionArgsExpG a
insertFunctionArg argName idx value (FunctionArgsExp positional named) =
  if (idx + 1) <= length positional
    then FunctionArgsExp (insertAt idx value positional) named
    else
      FunctionArgsExp positional $
        HM.insert (getFuncArgNameTxt argName) value named
  where
    insertAt i a = toList . Seq.insertAt i a . Seq.fromList

-- | The "distinct" input field inside "count" aggregate field
--
-- count (
--   distinct: Boolean
-- ): Int
data CountDistinct
  = SelectCountDistinct
  | SelectCountNonDistinct

-- Lenses

$(makeLenses ''AnnSelectG)
$(makeLenses ''AnnObjectSelectG)
$(makeLenses ''AnnRelationSelectG)
$(makeLenses ''ConnectionSelect)
$(makeLenses ''SelectArgsG)
$(makePrisms ''AnnFieldG)
$(makePrisms ''AnnotatedOrderByElement)
$(makePrisms ''TableAggregateFieldG)
$(makePrisms ''ConnectionField)
$(makePrisms ''EdgeField)
