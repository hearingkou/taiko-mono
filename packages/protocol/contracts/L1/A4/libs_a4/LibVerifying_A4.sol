// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/

pragma solidity ^0.8.20;

import {AddressResolver} from "../../../common/AddressResolver.sol";
import {IMintableERC20} from "../../../common/IMintableERC20.sol";
import {IProverPool} from "../ProverPool_A4.sol";
import {ISignalService} from "../../../signal/ISignalService.sol";
import {LibUtils_A4} from "./LibUtils_A4.sol";
import {LibMath} from "../../../libs/LibMath.sol";
import {SafeCastUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {TaikoData_A4} from "../TaikoData_A4.sol";
import {TaikoToken} from "../../TaikoToken.sol";
import {LibL2Consts} from "../../../L2/a4/LibL2Consts_A4.sol";

library LibVerifying {
    using SafeCastUpgradeable for uint256;
    using LibUtils_A4 for TaikoData_A4.State;
    using LibMath for uint256;

    event BlockVerified(uint256 indexed id, bytes32 blockHash, uint64 reward);

    event CrossChainSynced(uint256 indexed srcHeight, bytes32 blockHash, bytes32 signalRoot);

    error L1_INVALID_CONFIG();

    function init(
        TaikoData_A4.State storage state,
        TaikoData_A4.Config memory config,
        bytes32 genesisBlockHash,
        uint32 initFeePerGas,
        uint16 initAvgProofDelay
    ) internal {
        if (
            config.chainId <= 1 //
                || config.blockMaxProposals == 1
                || config.blockRingBufferSize <= config.blockMaxProposals + 1
                || config.blockMaxGasLimit == 0 || config.blockMaxTransactions == 0
                || config.blockMaxTxListBytes == 0 || config.blockTxListExpiry > 30 * 24 hours
                || config.blockMaxTxListBytes > 128 * 1024 //blob up to 128K
                || config.proofRegularCooldown < config.proofOracleCooldown
                || config.proofMinWindow == 0 || config.proofMaxWindow < config.proofMinWindow
                || config.ethDepositRingBufferSize <= 1 || config.ethDepositMinCountPerBlock == 0
                || config.ethDepositMaxCountPerBlock < config.ethDepositMinCountPerBlock
                || config.ethDepositMinAmount == 0
                || config.ethDepositMaxAmount <= config.ethDepositMinAmount
                || config.ethDepositMaxAmount >= type(uint96).max || config.ethDepositGas == 0
                || config.ethDepositMaxFee == 0 || config.ethDepositMaxFee >= type(uint96).max
                || config.ethDepositMaxFee >= type(uint96).max / config.ethDepositMaxCountPerBlock
                || config.rewardPerGasRange == 0 || config.rewardPerGasRange >= 10_000
                || config.rewardOpenMultipler < 100
        ) revert L1_INVALID_CONFIG();

        unchecked {
            uint64 timeNow = uint64(block.timestamp);

            // Init state
            state.genesisHeight = uint64(block.number);
            state.genesisTimestamp = timeNow;
            state.numBlocks = 1;
            state.lastVerifiedAt = uint64(block.timestamp);
            state.feePerGas = initFeePerGas;
            state.avgProofDelay = initAvgProofDelay;

            // Init the genesis block
            TaikoData_A4.Block storage blk = state.blocks[0];
            blk.nextForkChoiceId = 2;
            blk.verifiedForkChoiceId = 1;
            blk.proposedAt = timeNow;

            // Init the first fork choice
            TaikoData_A4.ForkChoice storage fc = state.blocks[0].forkChoices[1];
            fc.blockHash = genesisBlockHash;
            fc.provenAt = timeNow;
        }

        emit BlockVerified(0, genesisBlockHash, 0);
    }

    function verifyBlocks(
        TaikoData_A4.State storage state,
        TaikoData_A4.Config memory config,
        AddressResolver resolver,
        uint256 maxBlocks
    ) internal {
        uint256 i = state.lastVerifiedBlockId;
        TaikoData_A4.Block storage blk = state.blocks[i % config.blockRingBufferSize];

        uint24 fcId = blk.verifiedForkChoiceId;
        assert(fcId > 0);

        bytes32 blockHash = blk.forkChoices[fcId].blockHash;
        uint32 gasUsed = blk.forkChoices[fcId].gasUsed;
        bytes32 signalRoot;

        uint64 processed;
        unchecked {
            ++i;
        }

        while (i < state.numBlocks && processed < maxBlocks) {
            blk = state.blocks[i % config.blockRingBufferSize];
            assert(blk.blockId == i);

            fcId = LibUtils_A4.getForkChoiceId(state, blk, blockHash, gasUsed);
            if (fcId == 0) break;

            TaikoData_A4.ForkChoice memory fc = blk.forkChoices[fcId];
            if (fc.prover == address(0)) break;

            uint256 proofRegularCooldown =
                fc.prover == address(1) ? config.proofOracleCooldown : config.proofRegularCooldown;

            if (block.timestamp <= fc.provenAt + proofRegularCooldown) break;

            blockHash = fc.blockHash;
            gasUsed = fc.gasUsed;
            signalRoot = fc.signalRoot;

            _verifyBlock({
                state: state,
                config: config,
                resolver: resolver,
                blk: blk,
                fcId: fcId,
                fc: fc
            });

            unchecked {
                ++i;
                ++processed;
            }
        }

        if (processed > 0) {
            unchecked {
                state.lastVerifiedAt = uint64(block.timestamp);
                state.lastVerifiedBlockId += processed;
            }

            if (config.relaySignalRoot) {
                // Send the L2's signal root to the signal service so other
                // TaikoL1  deployments, if they share the same signal
                // service, can relay the signal to their corresponding
                // TaikoL2 contract.
                ISignalService(resolver.resolve("signal_service", false)).sendSignal(signalRoot);
            }
            emit CrossChainSynced(state.lastVerifiedBlockId, blockHash, signalRoot);
        }
    }

    function _verifyBlock(
        TaikoData_A4.State storage state,
        TaikoData_A4.Config memory config,
        AddressResolver resolver,
        TaikoData_A4.Block storage blk,
        TaikoData_A4.ForkChoice memory fc,
        uint24 fcId
    ) private {
        // the actually mined L2 block's gasLimit is blk.gasLimit +
        // LibL2Consts.ANCHOR_GAS_COST, so fc.gasUsed may greater than
        // blk.gasLimit here.
        uint32 _gasLimit = blk.gasLimit + LibL2Consts.ANCHOR_GAS_COST;
        assert(fc.gasUsed <= _gasLimit);

        IProverPool proverPool = IProverPool(resolver.resolve("prover_pool", false));

        if (blk.assignedProver == address(0)) {
            --state.numOpenBlocks;
        } else if (!blk.proverReleased) {
            proverPool.releaseProver(blk.assignedProver);
        }

        // Reward the prover (including the oracle prover)
        uint64 proofReward = (config.blockFeeBaseGas + fc.gasUsed) * blk.rewardPerGas;

        if (fc.prover == address(1)) {
            // system prover is rewarded with `proofReward`.
        } else if (blk.assignedProver == address(0)) {
            // open prover is rewarded with more tokens
            proofReward = proofReward * config.rewardOpenMultipler / 100;
        } else if (
            fc.prover == blk.assignedProver && fc.provenAt <= blk.proposedAt + blk.proofWindow
        ) {
            // The selected prover managed to prove the block in time
            state.avgProofDelay = uint16(
                LibUtils_A4.movingAverage({
                    maValue: state.avgProofDelay,
                    // TODO:  prover is not incentivized to submit proof
                    // ASAP
                    newValue: fc.provenAt - blk.proposedAt,
                    maf: 7200
                })
            );

            state.feePerGas = uint32(
                LibUtils_A4.movingAverage({
                    maValue: state.feePerGas,
                    newValue: blk.rewardPerGas,
                    maf: 7200
                })
            );
        } else {
            // proving out side of the proof window
            proofReward = proofReward * config.rewardOpenMultipler / 100;
            proverPool.slashProver(blk.assignedProver);
        }

        blk.verifiedForkChoiceId = fcId;

        // Reward the prover
        state.taikoTokenBalances[fc.prover] += proofReward;

        state.taikoTokenBalances[blk.proposer] += (_gasLimit - fc.gasUsed) * blk.feePerGas;

        emit BlockVerified(blk.blockId, fc.blockHash, proofReward);
    }
}
