module Hasura.GraphQL.Schema.RemoteRelationship
  ( remoteRelationshipField,
  )
where

import Control.Lens
import Data.Has
import Data.HashMap.Strict.Extended qualified as Map
import Data.List.NonEmpty qualified as NE
import Data.Text.Extended
import Hasura.Base.Error
import Hasura.GraphQL.Execute.Types qualified as ET
import Hasura.GraphQL.Parser
import Hasura.GraphQL.Parser qualified as P
import Hasura.GraphQL.Parser.Internal.Parser qualified as P
import Hasura.GraphQL.Schema.Backend
import Hasura.GraphQL.Schema.Common
import Hasura.GraphQL.Schema.Instances ()
import Hasura.GraphQL.Schema.Remote
import Hasura.GraphQL.Schema.Select
import Hasura.GraphQL.Schema.Table
import Hasura.Prelude
import Hasura.RQL.DDL.RemoteRelationship.Validate
import Hasura.RQL.IR qualified as IR
import Hasura.RQL.Types.Common (FieldName, RelType (..), relNameToTxt)
import Hasura.RQL.Types.Relationships.Remote
import Hasura.RQL.Types.Relationships.ToSchema
import Hasura.RQL.Types.Relationships.ToSchema qualified as Remote
import Hasura.RQL.Types.RemoteSchema
import Hasura.RQL.Types.ResultCustomization
import Hasura.RQL.Types.SchemaCache
import Hasura.RQL.Types.SourceCustomization (mkCustomizedTypename)
import Hasura.SQL.AnyBackend
import Hasura.Session
import Language.GraphQL.Draft.Syntax qualified as G

-- | Remote relationship field parsers
remoteRelationshipField ::
  forall r m n lhsJoinField.
  (MonadBuildSchemaBase r m n) =>
  RemoteFieldInfo lhsJoinField ->
  m (Maybe [FieldParser n (IR.RemoteRelationshipField UnpreparedValue)])
remoteRelationshipField RemoteFieldInfo {..} = runMaybeT do
  queryType <- asks $ qcQueryType . getter
  -- https://github.com/hasura/graphql-engine/issues/5144
  -- The above issue is easily fixable by removing the following guard
  guard $ queryType == ET.QueryHasura
  case _rfiRHS of
    RFISource anyRemoteSourceFieldInfo ->
      dispatchAnyBackend @BackendSchema anyRemoteSourceFieldInfo \remoteSourceFieldInfo -> do
        fields <- lift $ remoteRelationshipToSourceField remoteSourceFieldInfo
        pure $ fmap (IR.RemoteSourceField . mkAnyBackend) <$> fields
    RFISchema remoteSchema -> do
      fields <- MaybeT $ remoteRelationshipToSchemaField _rfiLHS remoteSchema
      pure $ pure $ IR.RemoteSchemaField <$> fields

-- | Parser(s) for remote relationship fields to a remote schema
remoteRelationshipToSchemaField ::
  forall r m n lhsJoinField.
  (MonadBuildSchemaBase r m n) =>
  Map.HashMap FieldName lhsJoinField ->
  RemoteSchemaFieldInfo ->
  m (Maybe (FieldParser n (IR.RemoteSchemaSelect (IR.RemoteRelationshipField UnpreparedValue))))
remoteRelationshipToSchemaField lhsFields RemoteSchemaFieldInfo {..} = runMaybeT do
  remoteRelationshipQueryCtx <- asks $ qcRemoteRelationshipContext . getter
  RemoteRelationshipQueryContext roleIntrospectionResultOriginal _ remoteSchemaCustomizer <-
    -- The remote relationship field should not be accessible
    -- if the remote schema is not accessible to the said role
    hoistMaybe $ Map.lookup _rrfiRemoteSchemaName remoteRelationshipQueryCtx
  roleName <- asks getter
  let hasuraFieldNames = Map.keysSet lhsFields
      relationshipDef = ToSchemaRelationshipDef _rrfiRemoteSchemaName hasuraFieldNames _rrfiRemoteFields
  (newInpValDefns :: [G.TypeDefinition [G.Name] RemoteSchemaInputValueDefinition], remoteFieldParamMap) <-
    if roleName == adminRoleName
      then do
        -- we don't validate the remote relationship when the role is admin
        -- because it's already been validated, when the remote relationship
        -- was created
        pure (_rrfiInputValueDefinitions, _rrfiParamMap)
      else do
        (_, roleRemoteField) <-
          afold @(Either _) $
            -- TODO: this really needs to go way, we shouldn't be doing
            -- validation when building parsers
            validateToSchemaRelationship relationshipDef _rrfiLHSIdentifier _rrfiName (_rrfiRemoteSchema, roleIntrospectionResultOriginal) lhsFields
        pure (Remote._rrfiInputValueDefinitions roleRemoteField, Remote._rrfiParamMap roleRemoteField)
  let roleIntrospection@(RemoteSchemaIntrospection typeDefns) = irDoc roleIntrospectionResultOriginal
      -- add the new input value definitions created by the remote relationship
      -- to the existing schema introspection of the role
      remoteRelationshipIntrospection = RemoteSchemaIntrospection $ typeDefns <> Map.fromListOn getTypeName newInpValDefns
  fieldName <- textToName $ relNameToTxt _rrfiName

  -- This selection set parser, should be of the remote node's selection set parser, which comes
  -- from the fieldCall
  let fieldCalls = unRemoteFields _rrfiRemoteFields
      parentTypeName = irQueryRoot roleIntrospectionResultOriginal
  nestedFieldType <- lift $ lookupNestedFieldType parentTypeName roleIntrospection fieldCalls
  let typeName = G.getBaseType nestedFieldType
  fieldTypeDefinition <-
    onNothing (lookupType roleIntrospection typeName)
    -- the below case will never happen because we get the type name
    -- from the schema document itself i.e. if a field exists for the
    -- given role, then it's return type also must exist
    $
      throw500 $ "unexpected: " <> typeName <<> " not found "
  -- These are the arguments that are given by the user while executing a query
  let remoteFieldUserArguments = map snd $ Map.toList remoteFieldParamMap
  remoteFld <-
    withRemoteSchemaCustomization remoteSchemaCustomizer $
      lift $
        P.wrapFieldParser nestedFieldType
          <$> remoteField remoteRelationshipIntrospection parentTypeName fieldName Nothing remoteFieldUserArguments fieldTypeDefinition

  pure $
    remoteFld
      `P.bindField` \fld@IR.GraphQLField {IR._fArguments = args, IR._fSelectionSet = selSet, IR._fName = fname} -> do
        let remoteArgs =
              Map.toList args <&> \(argName, argVal) -> IR.RemoteFieldArgument argName $ P.GraphQLValue argVal
        let resultCustomizer =
              applyFieldCalls fieldCalls $
                applyAliasMapping (singletonAliasMapping fname (fcName $ NE.last fieldCalls)) $
                  makeResultCustomizer remoteSchemaCustomizer fld
        pure $
          IR.RemoteSchemaSelect
            { IR._rselArgs = remoteArgs,
              IR._rselResultCustomizer = resultCustomizer,
              IR._rselSelection = selSet,
              IR._rselFieldCall = fieldCalls,
              IR._rselRemoteSchema = _rrfiRemoteSchema
            }
  where
    -- Apply parent field calls so that the result customizer modifies the nested field
    applyFieldCalls :: NonEmpty FieldCall -> ResultCustomizer -> ResultCustomizer
    applyFieldCalls fieldCalls resultCustomizer =
      foldr (modifyFieldByName . fcName) resultCustomizer $ NE.init fieldCalls

lookupNestedFieldType' ::
  (MonadSchema n m, MonadError QErr m) =>
  G.Name ->
  RemoteSchemaIntrospection ->
  FieldCall ->
  m G.GType
lookupNestedFieldType' parentTypeName remoteSchemaIntrospection (FieldCall fcName _) =
  case lookupObject remoteSchemaIntrospection parentTypeName of
    Nothing -> throw400 RemoteSchemaError $ "object with name " <> parentTypeName <<> " not found"
    Just G.ObjectTypeDefinition {..} ->
      case find ((== fcName) . G._fldName) _otdFieldsDefinition of
        Nothing -> throw400 RemoteSchemaError $ "field with name " <> fcName <<> " not found"
        Just G.FieldDefinition {..} -> pure _fldType

lookupNestedFieldType ::
  (MonadSchema n m, MonadError QErr m) =>
  G.Name ->
  RemoteSchemaIntrospection ->
  NonEmpty FieldCall ->
  m G.GType
lookupNestedFieldType parentTypeName remoteSchemaIntrospection (fieldCall :| rest) = do
  fieldType <- lookupNestedFieldType' parentTypeName remoteSchemaIntrospection fieldCall
  case NE.nonEmpty rest of
    Nothing -> pure fieldType
    Just rest' -> do
      lookupNestedFieldType (G.getBaseType fieldType) remoteSchemaIntrospection rest'

-- | Parser(s) for remote relationship fields to a database table.
-- Note that when the target is a database table, an array relationship
-- declaration would have the '_aggregate' field in addition to the array
-- relationship field, hence [FieldParser ...] instead of 'FieldParser'
remoteRelationshipToSourceField ::
  forall r m n tgt.
  (MonadBuildSchemaBase r m n, BackendSchema tgt) =>
  RemoteSourceFieldInfo tgt ->
  m [FieldParser n (IR.RemoteSourceSelect (IR.RemoteRelationshipField UnpreparedValue) UnpreparedValue tgt)]
remoteRelationshipToSourceField RemoteSourceFieldInfo {..} =
  withTypenameCustomization (mkCustomizedTypename $ Just _rsfiSourceCustomization) do
    tableInfo <- askTableInfo @tgt _rsfiSource _rsfiTable
    fieldName <- textToName $ relNameToTxt _rsfiName
    maybePerms <- tableSelectPermissions @tgt tableInfo
    case maybePerms of
      Nothing -> pure []
      Just tablePerms -> do
        parsers <- case _rsfiType of
          ObjRel -> do
            selectionSetParserM <- tableSelectionSet _rsfiSource tableInfo
            pure $ case selectionSetParserM of
              Nothing -> []
              Just selectionSetParser ->
                pure $
                  subselection_ fieldName Nothing selectionSetParser <&> \fields ->
                    IR.SourceRelationshipObject $
                      IR.AnnObjectSelectG fields _rsfiTable $ IR._tpFilter $ tablePermissionsInfo tablePerms
          ArrRel -> do
            let aggFieldName = fieldName <> $$(G.litName "_aggregate")
            selectionSetParser <- selectTable _rsfiSource tableInfo fieldName Nothing
            aggSelectionSetParser <- selectTableAggregate _rsfiSource tableInfo aggFieldName Nothing
            pure $
              catMaybes
                [ selectionSetParser <&> fmap IR.SourceRelationshipArray,
                  aggSelectionSetParser <&> fmap IR.SourceRelationshipArrayAggregate
                ]
        pure $
          parsers <&> fmap \select ->
            IR.RemoteSourceSelect _rsfiSource _rsfiSourceConfig select _rsfiMapping
