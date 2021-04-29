{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Test.Integration.Scenario.API.Shelley.SharedWallets
    ( spec
    ) where

import Prelude

import Cardano.Address.Script
    ( Cosigner (..), ScriptTemplate (..) )
import Cardano.Mnemonic
    ( MkSomeMnemonic (..) )
import Cardano.Wallet.Api.Types
    ( ApiSharedWallet (..)
    , DecodeAddress
    , DecodeStakeAddress
    , EncodeAddress (..)
    )
import Cardano.Wallet.Primitive.AddressDerivation
    ( DerivationIndex (..), Passphrase (..), PaymentAddress )
import Cardano.Wallet.Primitive.AddressDerivation.Shelley
    ( ShelleyKey )
import Cardano.Wallet.Primitive.AddressDiscovery.Script
    ( CredentialType (..) )
import Cardano.Wallet.Primitive.SyncProgress
    ( SyncProgress (..) )
import Control.Monad.IO.Class
    ( liftIO )
import Control.Monad.Trans.Resource
    ( runResourceT )
import Data.Bifunctor
    ( second )
import Data.Generics.Internal.VL.Lens
    ( (^.) )
import Data.Quantity
    ( Quantity (..) )
import Data.Text.Class
    ( ToText (..) )
import Test.Hspec
    ( SpecWith, describe, shouldBe, shouldNotBe )
import Test.Hspec.Extra
    ( it )
import Test.Integration.Framework.DSL
    ( Context (..)
    , Headers (..)
    , MnemonicLength (..)
    , Payload (..)
    , accPubKeyFromMnemonics
    , deleteSharedWallet
    , eventually
    , expectErrorMessage
    , expectField
    , expectResponseCode
    , fixturePassphrase
    , genMnemonics
    , genXPubs
    , getFromResponse
    , getSharedWallet
    , json
    , notDelegating
    , patchSharedWallet
    , postSharedWallet
    , verify
    )
import Test.Integration.Framework.TestData
    ( errMsg403CannotUpdateThisCosigner
    , errMsg403CreateIllegal
    , errMsg403KeyAlreadyPresent
    , errMsg403NoDelegationTemplate
    , errMsg403NoSuchCosigner
    , errMsg403WalletAlreadyActive
    )

import qualified Data.ByteArray as BA
import qualified Data.Map.Strict as Map
import qualified Data.Text.Encoding as T
import qualified Network.HTTP.Types as HTTP

spec :: forall n.
    ( DecodeAddress n
    , DecodeStakeAddress n
    , EncodeAddress n
    , PaymentAddress n ShelleyKey
    ) => SpecWith Context
spec = describe "SHARED_WALLETS" $ do
    it "SHARED_WALLETS_CREATE_01 - Create an active shared wallet from root xprv" $ \ctx -> runResourceT $ do
        m15txt <- liftIO $ genMnemonics M15
        m12txt <- liftIO $ genMnemonics M12
        let (Right m15) = mkSomeMnemonic @'[ 15 ] m15txt
        let (Right m12) = mkSomeMnemonic @'[ 12 ] m12txt
        let passphrase = Passphrase $ BA.convert $ T.encodeUtf8 fixturePassphrase
        let accXPubDerived = accPubKeyFromMnemonics m15 (Just m12) 30 passphrase
        let payload = Json [json| {
                "name": "Shared Wallet",
                "mnemonic_sentence": #{m15txt},
                "mnemonic_second_factor": #{m12txt},
                "passphrase": #{fixturePassphrase},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubDerived} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               { "active_from": 120 }
                             ]
                          }
                    }
                } |]
        r <- postSharedWallet ctx Default payload
        verify (second (\(Right (ApiSharedWallet (Right res))) -> Right res) r)
            [ expectResponseCode HTTP.status201
            , expectField
                    (#name . #getApiT . #getWalletName) (`shouldBe` "Shared Wallet")
            , expectField
                    (#addressPoolGap . #getApiT . #getAddressPoolGap) (`shouldBe` 20)
            , expectField (#balance . #available) (`shouldBe` Quantity 0)
            , expectField (#balance . #total) (`shouldBe` Quantity 0)
            , expectField (#balance . #reward) (`shouldBe` Quantity 0)
            , expectField (#assets . #total) (`shouldBe` mempty)
            , expectField (#assets . #available) (`shouldBe` mempty)
            , expectField #delegation (`shouldBe` notDelegating [])
            , expectField #passphrase (`shouldNotBe` Nothing)
            , expectField #delegationScriptTemplate (`shouldBe` Nothing)
            , expectField (#accountIndex . #getApiT) (`shouldBe` DerivationIndex 2147483678)
            ]

    it "SHARED_WALLETS_CREATE_02 - Create a pending shared wallet from root xprv" $ \ctx -> runResourceT $ do
        m15txt <- liftIO $ genMnemonics M15
        m12txt <- liftIO $ genMnemonics M12
        let (Right m15) = mkSomeMnemonic @'[ 15 ] m15txt
        let (Right m12) = mkSomeMnemonic @'[ 12 ] m12txt
        let passphrase = Passphrase $ BA.convert $ T.encodeUtf8 fixturePassphrase
        let accXPubDerived = accPubKeyFromMnemonics m15 (Just m12) 30 passphrase
        let payload = Json [json| {
                "name": "Shared Wallet",
                "mnemonic_sentence": #{m15txt},
                "mnemonic_second_factor": #{m12txt},
                "passphrase": #{fixturePassphrase},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubDerived} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               "cosigner#1",
                               { "active_from": 120 }
                             ]
                          }
                    }
                } |]
        r <- postSharedWallet ctx Default payload
        verify (second (\(Right (ApiSharedWallet (Left res))) -> Right res) r)
            [ expectResponseCode HTTP.status201
            , expectField
                    (#name . #getApiT . #getWalletName) (`shouldBe` "Shared Wallet")
            , expectField
                    (#addressPoolGap . #getApiT . #getAddressPoolGap) (`shouldBe` 20)
            , expectField #delegationScriptTemplate (`shouldBe` Nothing)
            , expectField (#accountIndex . #getApiT) (`shouldBe` DerivationIndex 2147483678)
            ]

    it "SHARED_WALLETS_CREATE_03 - Create an active shared wallet from account xpub" $ \ctx -> runResourceT $ do
        (_, accXPubTxt):_ <- liftIO $ genXPubs 1
        let payload = Json [json| {
                "name": "Shared Wallet",
                "account_public_key": #{accXPubTxt},
                "account_index": "10H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               { "active_from": 120 }
                             ]
                          }
                    }
                } |]
        r <- postSharedWallet ctx Default payload
        verify (second (\(Right (ApiSharedWallet (Right res))) -> Right res) r)
            [ expectResponseCode HTTP.status201
            , expectField
                    (#name . #getApiT . #getWalletName) (`shouldBe` "Shared Wallet")
            , expectField
                    (#addressPoolGap . #getApiT . #getAddressPoolGap) (`shouldBe` 20)
            , expectField (#balance . #available) (`shouldBe` Quantity 0)
            , expectField (#balance . #total) (`shouldBe` Quantity 0)
            , expectField (#balance . #reward) (`shouldBe` Quantity 0)
            , expectField (#assets . #total) (`shouldBe` mempty)
            , expectField (#assets . #available) (`shouldBe` mempty)
            , expectField #delegation (`shouldBe` notDelegating [])
            , expectField #passphrase (`shouldBe` Nothing)
            , expectField #delegationScriptTemplate (`shouldBe` Nothing)
            , expectField (#accountIndex . #getApiT) (`shouldBe` DerivationIndex 2147483658)
            ]

    it "SHARED_WALLETS_CREATE_04 - Create a pending shared wallet from account xpub" $ \ctx -> runResourceT $ do
        (_, accXPubTxt):_ <- liftIO $ genXPubs 1
        let payload = Json [json| {
                "name": "Shared Wallet",
                "account_public_key": #{accXPubTxt},
                "account_index": "10H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               "cosigner#1",
                               { "active_from": 120 }
                             ]
                          }
                    }
                } |]
        r <- postSharedWallet ctx Default payload
        verify (second (\(Right (ApiSharedWallet (Left res))) -> Right res) r)
            [ expectResponseCode HTTP.status201
            , expectField
                    (#name . #getApiT . #getWalletName) (`shouldBe` "Shared Wallet")
            , expectField
                    (#addressPoolGap . #getApiT . #getAddressPoolGap) (`shouldBe` 20)
            , expectField #delegationScriptTemplate (`shouldBe` Nothing)
            , expectField (#accountIndex . #getApiT) (`shouldBe` DerivationIndex 2147483658)
            ]

    it "SHARED_WALLETS_DELETE_01 - Delete of a shared wallet" $ \ctx -> runResourceT $ do
        (_, accXPubTxt):_ <- liftIO $ genXPubs 1
        let payload = Json [json| {
                "name": "Shared Wallet",
                "account_public_key": #{accXPubTxt},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               { "active_from": 120 }
                             ]
                          }
                    }
                } |]
        rInit <- postSharedWallet ctx Default payload
        verify rInit
            [ expectResponseCode HTTP.status201 ]
        let wal = getFromResponse id rInit

        eventually "Wallet state = Ready" $ do
            r <- getSharedWallet ctx wal
            verify (second (\(Right (ApiSharedWallet (Right res))) -> Right res) r)
                [ expectField (#state . #getApiT) (`shouldBe` Ready) ]

        rDel <- deleteSharedWallet ctx wal
        expectResponseCode HTTP.status204 rDel

    it "SHARED_WALLETS_PATCH_01 - Add cosigner key in a pending shared wallet and transit it to the active shared wallet" $ \ctx -> runResourceT $ do
        [(accXPub0, accXPubTxt0),(accXPub1,accXPubTxt1)] <- liftIO $ genXPubs 2

        let payloadCreate = Json [json| {
                "name": "Shared Wallet",
                "account_public_key": #{accXPubTxt0},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt0} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               "cosigner#1",
                               { "active_from": 120 }
                             ]
                          }
                    }
                } |]
        rPost <- postSharedWallet ctx Default payloadCreate
        expectResponseCode HTTP.status201 rPost
        let wal@(ApiSharedWallet (Left pendingWal)) = getFromResponse id rPost
        let cosignerKeysPost = pendingWal ^. #paymentScriptTemplate
        liftIO $ cosigners cosignerKeysPost `shouldBe` Map.fromList [(Cosigner 0,accXPub0)]

        let payloadPatch = Json [json| {
                "cosigner#1": #{accXPubTxt1}
                } |]

        rPatch <- patchSharedWallet ctx wal Payment payloadPatch
        expectResponseCode HTTP.status200 rPatch
        let (ApiSharedWallet (Right activeWal)) = getFromResponse id rPatch
        let cosignerKeysPatch = activeWal ^. #paymentScriptTemplate
        liftIO $ cosigners cosignerKeysPatch `shouldBe` Map.fromList [(Cosigner 0,accXPub0), (Cosigner 1,accXPub1)]

    it "SHARED_WALLETS_PATCH_02 - Add cosigner for delegation script template" $ \ctx -> runResourceT $ do
        [(accXPub0, accXPubTxt0),(accXPub1,accXPubTxt1)] <- liftIO $ genXPubs 2
        let payloadCreate = Json [json| {
                "name": "Shared Wallet",
                "account_public_key": #{accXPubTxt0},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt0} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               { "active_from": 120 }
                             ]
                          }
                    },
                "delegation_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt0} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               "cosigner#1",
                               { "active_from": 120 },
                               { "active_until": 100 }
                             ]
                          }
                    }
                } |]
        rPost <- postSharedWallet ctx Default payloadCreate
        expectResponseCode HTTP.status201 rPost
        let wal@(ApiSharedWallet (Left pendingWal)) = getFromResponse id rPost
        let cosignerKeysPostInPayment = pendingWal ^. #paymentScriptTemplate
        liftIO $ cosigners cosignerKeysPostInPayment `shouldBe` Map.fromList [(Cosigner 0,accXPub0)]
        let (Just cosignerKeysPostInDelegation) = pendingWal ^. #delegationScriptTemplate
        liftIO $ cosigners cosignerKeysPostInDelegation `shouldBe` Map.fromList [(Cosigner 0,accXPub0)]

        let payloadPatch = Json [json| {
                "cosigner#1": #{accXPubTxt1}
                } |]

        rPatch <- patchSharedWallet ctx wal Delegation payloadPatch
        expectResponseCode HTTP.status200 rPatch
        let (ApiSharedWallet (Right activeWal)) = getFromResponse id rPatch
        let (Just cosignerKeysPatch) = activeWal ^. #delegationScriptTemplate
        liftIO $ cosigners cosignerKeysPatch `shouldBe` Map.fromList [(Cosigner 0,accXPub0), (Cosigner 1,accXPub1)]

    it "SHARED_WALLETS_PATCH_03 - Cannot add cosigner key in an active shared wallet" $ \ctx -> runResourceT $ do
        [(_, accXPubTxt0),(_,accXPubTxt1)] <- liftIO $ genXPubs 2
        let payloadCreate = Json [json| {
                "name": "Shared Wallet",
                "account_public_key": #{accXPubTxt0},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt0} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               { "active_from": 120 }
                             ]
                          }
                    }
                } |]
        rPost <- postSharedWallet ctx Default payloadCreate
        expectResponseCode HTTP.status201 rPost
        let wal@(ApiSharedWallet (Right _activeWal)) = getFromResponse id rPost

        let payloadPatch = Json [json| {
                "cosigner#1": #{accXPubTxt1}
                } |]

        rPatch <- patchSharedWallet ctx wal Payment payloadPatch
        expectResponseCode HTTP.status403 rPatch
        expectErrorMessage errMsg403WalletAlreadyActive rPatch

    it "SHARED_WALLETS_PATCH_04 - Cannot add cosigner key when delegation script missing and cannot add already existant key to other cosigner" $ \ctx -> runResourceT $ do
        [(_, accXPubTxt0),(_,accXPubTxt1)] <- liftIO $ genXPubs 2
        let payloadCreate = Json [json| {
                "name": "Shared Wallet",
                "account_public_key": #{accXPubTxt0},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt0} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               "cosigner#1",
                               { "active_from": 120 }
                             ]
                          }
                    }
                } |]
        rPost <- postSharedWallet ctx Default payloadCreate
        expectResponseCode HTTP.status201 rPost
        let wal@(ApiSharedWallet (Left _pendingWal)) = getFromResponse id rPost

        let payloadPatch = Json [json| {
                "cosigner#1": #{accXPubTxt1}
                } |]

        rPatch <- patchSharedWallet ctx wal Delegation payloadPatch
        expectResponseCode HTTP.status403 rPatch
        expectErrorMessage errMsg403NoDelegationTemplate rPatch

    it "SHARED_WALLETS_PATCH_05 - Cannot create shared wallet when missing wallet's account public key in template" $ \ctx -> runResourceT $ do
        [(_, accXPubTxt0),(_,accXPubTxt1)] <- liftIO $ genXPubs 2
        let payloadCreate = Json [json| {
                "name": "Shared Wallet",
                "account_public_key": #{accXPubTxt0},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt1} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               "cosigner#1",
                               { "active_from": 120 }
                             ]
                          }
                    }
                } |]
        rPost <- postSharedWallet ctx Default payloadCreate
        expectResponseCode HTTP.status403 rPost
        expectErrorMessage errMsg403CreateIllegal rPost

    it "SHARED_WALLETS_PATCH_06 - Can add the same cosigner key for delegation script template but not payment one" $ \ctx -> runResourceT $ do
        [(_, accXPubTxt0),(_,accXPubTxt1)] <- liftIO $ genXPubs 2
        let payloadCreate = Json [json| {
                "name": "Shared Wallet",
                "account_public_key": #{accXPubTxt0},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt0} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               "cosigner#1",
                               { "active_from": 120 }
                             ]
                          }
                    },
                "delegation_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt0} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               "cosigner#1",
                               { "active_from": 120 },
                               { "active_until": 100 }
                             ]
                          }
                    }
                } |]
        rPost <- postSharedWallet ctx Default payloadCreate
        expectResponseCode HTTP.status201 rPost
        let wal@(ApiSharedWallet (Left _pendingWal)) = getFromResponse id rPost

        let payloadPatch1 = Json [json| {
                "cosigner#1": #{accXPubTxt1}
                } |]
        rPatch1 <- patchSharedWallet ctx wal Delegation payloadPatch1
        expectResponseCode HTTP.status200 rPatch1

        let payloadPatch2 = Json [json| {
                "cosigner#0": #{accXPubTxt0}
                } |]
        rPatch2 <- patchSharedWallet ctx wal Payment payloadPatch2
        expectResponseCode HTTP.status403 rPatch2
        expectErrorMessage errMsg403CannotUpdateThisCosigner rPatch2

        let payloadPatch3 = Json [json| {
                "cosigner#1": #{accXPubTxt0}
                } |]
        rPatch3 <- patchSharedWallet ctx wal Payment payloadPatch3
        expectResponseCode HTTP.status403 rPatch3
        expectErrorMessage (errMsg403KeyAlreadyPresent (toText Payment)) rPatch3

        let payloadPatch4 = Json [json| {
                "cosigner#1": #{accXPubTxt1}
                } |]
        rPatch4 <- patchSharedWallet ctx wal Delegation payloadPatch4
        expectResponseCode HTTP.status403 rPatch4
        expectErrorMessage (errMsg403KeyAlreadyPresent (toText Delegation)) rPatch4

        let payloadPatch5 = Json [json| {
                "cosigner#7": #{accXPubTxt0}
                } |]
        rPatch5 <- patchSharedWallet ctx wal Payment payloadPatch5
        expectResponseCode HTTP.status403 rPatch5
        expectErrorMessage (errMsg403NoSuchCosigner (toText Payment) 7) rPatch5

    it "SHARED_WALLETS_PATCH_07 - Cannot update cosigner key in a pending shared wallet having the shared wallet's account key" $ \ctx -> runResourceT $ do
        [(_, accXPubTxt0),(_,accXPubTxt1)] <- liftIO $ genXPubs 2
        let payloadCreate = Json [json| {
                "name": "Shared Wallet",
                "account_public_key": #{accXPubTxt0},
                "account_index": "30H",
                "payment_script_template":
                    { "cosigners":
                        { "cosigner#0": #{accXPubTxt0} },
                      "template":
                          { "all":
                             [ "cosigner#0",
                               "cosigner#1",
                               { "active_from": 120 }
                             ]
                          }
                    }
                } |]
        rPost <- postSharedWallet ctx Default payloadCreate
        expectResponseCode HTTP.status201 rPost
        let wal@(ApiSharedWallet (Left _pendingWal)) = getFromResponse id rPost

        let payloadPatch = Json [json| {
                "cosigner#0": #{accXPubTxt1}
                } |]
        rPatch <- patchSharedWallet ctx wal Payment payloadPatch
        expectResponseCode HTTP.status403 rPatch
        expectErrorMessage errMsg403CannotUpdateThisCosigner rPatch