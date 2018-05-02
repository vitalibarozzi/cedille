module CedilleCoreCheck where
import CedilleCoreTypes
import CedilleCoreCtxt
import CedilleCoreNorm
import CedilleCoreToString

errIf True e = err e
errIf False _ = Right ()
errIfNot = errIf . not
appendShowErr f tm = case f tm of
  Left ('!' : e) -> Left $ e ++ ", in the expression \"" ++ show tm ++ "\""
  r -> r
err s = Left ('!' : s)

--errIfCtxtBinds :: Ctxt -> Var -> Either String ()
errIfCtxtBinds c v = errIf (ctxtBindsVar c v) ("Repeated variable in scope: " ++ v)

--isValidTerm :: Ctxt -> PureTerm -> Either String ()
isValidTerm c (PureVar v) = maybe (err ("Term variable not in scope: " ++ v)) (\ _ -> Right ()) (ctxtLookupTerm c v)
isValidTerm c (PureApp tm tm') = isValidTerm c tm >> isValidTerm c tm'
isValidTerm c (PureLambda v tm) = isValidTerm (ctxtDefTerm c v (Just (PureVar v), Nothing)) tm

typeHasKindStar (TpLambda v tk tp) = err "Expected a type of kind Star"
typeHasKindStar _ = Right ()

--isValidType :: Ctxt -> PureType -> Either String ()
isValidType c (TpVar v) = maybe (err ("Type variable not in scope: " ++ v)) (\ _ -> Right ()) (ctxtLookupType c v)
isValidType c (TpLambda v tk tp) = isValidTpKd c tk >> isValidType (ctxtDefTpKd c v tk) tp
isValidType c (TpAll v tk tp) = isValidTpKd c tk >> isValidType (ctxtDefTpKd c v tk) tp
isValidType c (TpPi v tp tp') = isValidType c tp >> isValidType (ctxtDefTerm c v (Nothing, Just tp)) tp'
isValidType c (TpIota v tp tp') = isValidType c tp >> isValidType (ctxtDefTerm c v (Nothing, Just tp)) tp'
isValidType c (TpAppTp tp tp') = isValidType c tp >> isValidType c tp'
isValidType c (TpAppTm tp tm) = isValidType c tp >> isValidTerm c tm
isValidType c (TpEq tm tm') = isValidTerm c tm >> isValidTerm c tm'

--isValidKind :: Ctxt -> PureKind -> Either String ()
isValidKind c Star = Right ()
isValidKind c (KdPi v tk kd) = isValidTpKd c tk >> isValidKind (ctxtDefTpKd c v tk) kd

--isValidTpKd :: Ctxt -> PureTpKd -> Either String ()
isValidTpKd c (TpKdt tp) = isValidType c tp
isValidTpKd c (TpKdk kd) = isValidKind c kd

--checkType :: Ctxt -> Type -> Either String PureKind
checkType c tp = synthType c tp >>= \ kd ->
  errIfNot (convKind c kd Star) "Type must have kind star" >> Right kd

--checkTpKd :: Ctxt -> TpKd -> Either String (Either PureKind ())
checkTpKd c (TpKdt tp) = checkType c tp >>= Right . Left
checkTpKd c (TpKdk kd) = synthKind c kd >>= Right . Right

synthTerm = appendShowErr . synthTerm'
synthType = appendShowErr . synthType'
synthKind = appendShowErr . synthKind'
synthTpKd = appendShowErr . synthTpKd'

--synthTerm' :: Ctxt -> Term -> Either String PureType
synthTerm' c (TmVar v) = maybe (err "Term variable not in scope") Right (ctxtLookupVarType c v)
synthTerm' c (TmLambda v tp tm) =
  errIfCtxtBinds c v >>
  synthType c tp >>
  let tp' = hnfeType c tp in
  synthTerm (ctxtDefTerm c v (Nothing, Just tp')) tm >>= Right . TpPi v tp'
synthTerm' c (TmLambdaE v tk tm) =
  errIfCtxtBinds c v >>
  errIf (freeInTerm v (eraseTerm tm))
    ("Implicit variable occurs free in its body: " ++ v) >>
  checkTpKd c tk >>
  let tk' = hnfeTpKd c tk in
  synthTerm (ctxtDefTpKd c v tk') tm >>= Right . TpAll v tk'
synthTerm' c (TmAppTm ltm rtm) =
  synthTerm c ltm >>= \ ltp -> case ltp of
    (TpPi v ltph ltpb) -> synthTerm c rtm >>= \ rtp ->
      errIfNot (convType c ltph rtp) (show ltph ++ " != " ++ show rtp) >>
      Right (hnfType (ctxtInternalDef c v (Left (hnfeTerm c rtm))) ltpb)
    _ -> err "Expected the head of an application to synthesize a pi type"
synthTerm' c (TmAppTmE ltm rtm) =
  synthTerm c ltm >>= \ ltp -> case ltp of
    (TpAll v (TpKdt ltph) ltpb) -> synthTerm c rtm >>= \ rtp ->
      errIfNot (convType c ltph rtp) (show ltph ++ " != " ++ show rtp) >>
      Right (hnfType (ctxtInternalDef c v (Left (hnfeTerm c rtm))) ltpb)
    _ -> err "Expected the head of an application to synthesize a type-forall type"
synthTerm' c (TmAppTp tm tp) =
  synthTerm c tm >>= \ ltp -> case ltp of
    (TpAll v (TpKdk lkdh) ltpb) -> synthType c tp >>= \ rkd ->
      errIfNot (convKind c lkdh rkd) (show lkdh ++ " != " ++ show rkd) >>
      Right (hnfType (ctxtInternalDef c v (Right (hnfeType c tp))) ltpb)
    _ -> err "Expected the head of an application to synthesize a kind-forall type"
synthTerm' c (TmIota tm tm' v tp) =
  errIfCtxtBinds c v >>
  errIfNot (convTerm c (eraseTerm tm) (eraseTerm tm')) ("In a iota pair, " ++ show (hnfeTerm c tm) ++ " != " ++ show (hnfeTerm c tm')) >>
  synthTerm c tm >>= \ ltp ->
  synthTerm c tm' >>= \ rtp ->
  let c' = ctxtInternalDef c v (Left (hnfeTerm (ctxtRename c v v) tm)) in
  let tp' = hnfeType c' tp in
  isValidType c' tp' >>
  typeHasKindStar tp' >>
  let etp = eraseType tp in
  errIfNot (convType c' etp rtp) "Inconvertible types in a iota pair" >>
  Right (TpIota v ltp (hnfType (ctxtRename c v v) etp))
synthTerm' c (IotaProj1 tm) = synthTerm c tm >>= \ tp -> case hnfType c tp of
  (TpIota v tp tp') -> Right (hnfType c tp)
  _ -> err "Expected a iota type"
synthTerm' c (IotaProj2 tm) = synthTerm c tm >>= \ tp -> case hnfType c tp of
  (TpIota v tp tp') -> Right (hnfType (ctxtInternalDef c v (Left (hnfeTerm (ctxtRename c v v) tm))) tp')
  _ -> err "Expected a iota type"
synthTerm' c (Beta pt pt') =
  isValidTerm c pt >>
  isValidTerm c pt' >>
  Right (TpEq pt pt)
synthTerm' c (Sigma tm) = synthTerm c tm >>= \ tp -> case tp of
  (TpEq ltm rtm) -> Right (TpEq rtm ltm)
  _ -> err "Expected to synthesize an equational type from the body of a sigma term"
synthTerm' c (Delta tp tm) =
  doRename' c "x" $ \ x ->
  doRename' c "y" $ \ y ->
  synthTerm c tm >>= \ tp' ->
  let tt = PureLambda x (PureLambda y (PureVar x)) in
  let ff = PureLambda x (PureLambda y (PureVar y)) in
  isValidType c tp >>
  errIfNot (convType c tp' (TpEq tt ff))
    "Could not synthesize a contradiction from the body of a delta term" >>
  Right (hnfType c tp)
synthTerm' c (Rho tm v tp tm') =
  errIfCtxtBinds c v >>
  synthTerm c tm >>= \ eqtp ->
  synthTerm c tm' >>= \ btp ->
  case eqtp of
    (TpEq ltm rtm) ->
      errIfNot (convType (ctxtInternalDef c v (Left (substTerm c ltm))) btp tp) "Inconvertible types after rewriting in a rho term" >>
      Right (substType (ctxtInternalDef c v (Left (substTerm c rtm))) tp)
    _ -> err "Could not synthesize an equation from the first term in a rho term"
synthTerm' c (Phi tm tm' pt) =
  synthTerm c tm >>= \ eqtp ->
  synthTerm c tm' >>= \ rettp ->
  isValidTerm c pt >>
  errIfNot (convType c eqtp (TpEq (hnfeTerm c tm') pt))
    "Could not synthesize an equation for the terms in a phi term" >>
  Right rettp

--synthType' :: Ctxt -> Type -> Either String PureKind
synthType' c (TpVar v) = maybe (err "Type variable not in scope") Right (ctxtLookupVarKind c v)
synthType' c (TpLambda v tk tp) =
  errIfCtxtBinds c v >>
  checkTpKd c tk >>
  let tk' = hnfeTpKd c tk in
  synthType (ctxtDefTpKd c v tk') tp >>= Right . KdPi v tk'
synthType' c (TpAll v tk tp) =
  errIfCtxtBinds c v >>
  checkTpKd c tk >>
  let tk' = hnfeTpKd c tk in
  checkType (ctxtDefTpKd c v tk') tp
synthType' c (TpPi v tp tp') =
  errIfCtxtBinds c v >>
  checkType c tp >>
  let tp'' = hnfeType c tp in
  checkType (ctxtDefTerm c v (Nothing, Just tp'')) tp'
synthType' c (TpIota v tp tp') =
  errIfCtxtBinds c v >>
  checkType c tp >>
  let tp'' = hnfeType c tp in
  checkType (ctxtDefTerm c v (Nothing, Just tp'')) tp'
synthType' c (TpAppTp tp tp') =
  synthType c tp >>= \ kd ->
  synthType c tp' >>= \ kd' ->
  case kd of
    (KdPi v (TpKdk kd'') retkd) ->
      errIfNot (convKind c kd' kd'') (show kd'' ++ " != " ++ show kd') >>
      Right retkd
    _ -> err "Expected the head of an application to synthesize a kind-pi binding a kind"
synthType' c (TpAppTm tp tm) =
  synthType c tp >>= \ kd ->
  synthTerm c tm >>= \ tp' ->
  case kd of
    (KdPi v (TpKdt tp'') retkd) ->
      errIfNot (convType c tp' tp'') (show tp'' ++ " != " ++ show tp') >>
      Right retkd
    _ -> err "Expected the head of an application to synthesize a kind-pi binding a type"
synthType' c (TpEq tm tm') =
  isValidTerm c tm >>
  isValidTerm c tm' >>
  Right Star

--synthKind' :: Ctxt -> Kind -> Either String ()
synthKind' c Star = Right ()
synthKind' c (KdPi v tk kd) =
  errIfCtxtBinds c v >>
  checkTpKd c tk >>
  synthKind (ctxtDefTpKd c v (hnfeTpKd c tk)) kd

--synthTpKd' :: Ctxt -> TpKd -> Either String (Either PureKind ())
synthTpKd' c (TpKdt tp) = synthType c tp >>= Right . Left
synthTpKd' c (TpKdk kd) = synthKind c kd >>= Right . Right
