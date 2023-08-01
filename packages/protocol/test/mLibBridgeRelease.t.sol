// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/

pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { AddressResolver } from "../contracts/common/AddressResolver.sol";
import { EtherVault } from "../contracts/bridge/EtherVault.sol";
import { IBridge } from "../contracts/bridge/IBridge.sol";
import { LibBridgeData } from "../contracts/bridge/libs/LibBridgeData.sol";
import { LibBridgeStatus } from "../contracts/bridge/libs/LibBridgeStatus.sol";

interface VaultContract {
    function releaseToken(IBridge.Message calldata message) external;
}
/**
 * This library provides functions for releasing Ether related to message
 * execution on the Bridge.
 */

library LibBridgeRelease {
    using LibBridgeData for IBridge.Message;

    event EtherReleased(bytes32 indexed msgHash, address to, uint256 amount);

    error B_TOKENS_RELEASED_ALREADY();
    error B_FAILED_TRANSFER();
    error B_MSG_NOT_FAILED();
    error B_OWNER_IS_NULL();
    error B_WRONG_CHAIN_ID();

    /**
     * Release Ether to the message owner
     * @dev This function releases Ether to the message owner, only if the
     * Bridge state says:
     * - Ether for this message has not been released before.
     * - The message is in a failed state.
     * @param state The current state of the Bridge
     * @param resolver The AddressResolver instance
     * @param message The message whose associated Ether should be released
     */
    function recallMessage(
        LibBridgeData.State storage state,
        AddressResolver resolver,
        IBridge.Message calldata message,
        bytes calldata
    )
        internal
    {
        if (message.owner == address(0)) {
            revert B_OWNER_IS_NULL();
        }

        if (message.srcChainId != block.chainid) {
            revert B_WRONG_CHAIN_ID();
        }

        bytes32 msgHash = message.hashMessage();

        ///////////////////////////
        //  Mock to avoid valid  //
        //  proofs.This part is  //
        //  already tested in    //
        //  in other tests with  //
        //  valid proofs.        //
        ///////////////////////////
        if (false) {
            revert B_MSG_NOT_FAILED();
        }
        
        if(state.recallStatus[msgHash] 
                == LibBridgeData.RecallStatus.ETH_AND_TOKEN_RELEASED
        ){
            // Both ether and tokens are released
            revert B_TOKENS_RELEASED_ALREADY();
        }

        uint256 releaseAmount;

        if(state.recallStatus[msgHash] 
                == LibBridgeData.RecallStatus.NOT_RECALLED
        ) {
            // Release ETH first
            state.recallStatus[msgHash] = LibBridgeData.RecallStatus.ETH_RELEASED;

            releaseAmount = message.depositValue + message.callValue;

            if (releaseAmount > 0) {
                address ethVault = resolver.resolve("ether_vault", true);
                // if on Taiko
                if (ethVault != address(0)) {
                    EtherVault(payable(ethVault)).releaseEther(
                        message.owner, releaseAmount
                    );
                } else {
                    // if on Ethereum
                    (bool success,) = message.owner.call{ value: releaseAmount }("");
                    if (!success) {
                        revert B_FAILED_TRANSFER();
                    }
                }
            }
        }
        //2nd stage is releasing the tokens
        if(state.recallStatus[msgHash] 
                == LibBridgeData.RecallStatus.ETH_RELEASED 
                && message.to != address(0)
                && message.data.length != 0
        ) {
            // We now, need to know which tokenVault 'IS' the one. So from message.to - we cannot
            // really query that because it contains the destination address so we need to 'trial
            // and error.'
            // We have 3 vaults, so we need to try to get those and execute
            for (uint i = 0; i < 3; i++) { 
                // Now try to process message.data via calling the releaseToken() on
                // the proper vault
                state.recallStatus[msgHash] =
                    LibBridgeData.RecallStatus.ETH_AND_TOKEN_RELEASED;
                try VaultContract(
                    _getVaultSrcChain(message.srcChainId,i)
                ).releaseToken(message){
                    //If sucess, then break
                    break;
                } catch {
                    // If it had a token (erc20/721/1115) try to release
                    // it and if unsuccessfull set the status back
                    state.recallStatus[msgHash] = LibBridgeData.RecallStatus.ETH_RELEASED;
                }
            }
        }
        emit EtherReleased(msgHash, message.owner, releaseAmount);
    }

    function _getVaultSrcChain(
        uint srcChainId,
        uint256 idx
    )
        internal
        view
        returns(address retVal)
    {
        if (idx == 0) {
            return AddressResolver(address(this)).resolve(
                    srcChainId, "erc20_vault", false
                );
        }
        else if (idx == 1) {
            return AddressResolver(address(this)).resolve(
                    srcChainId, "erc721_vault", false
                );
        }
        else if (idx == 2) {
            return AddressResolver(address(this)).resolve(
                    srcChainId, "erc1155_vault", false
                );
        }
    }
}

