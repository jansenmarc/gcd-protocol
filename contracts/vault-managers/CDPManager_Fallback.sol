// SPDX-License-Identifier: bsl-1.1

/*
  Copyright 2020 Unit Protocol: Artem Zakharov (az@unit.xyz).
*/
pragma solidity 0.7.6;
pragma abicoder v2;

import '../interfaces/IOracleRegistry.sol';
import '../oracles/KeydonixOracleAbstract.sol';
import '../interfaces/IToken.sol';
import '../interfaces/IVault.sol';
import '../interfaces/ICDPRegistry.sol';
import '../interfaces/IVaultManagerParameters.sol';
import '../interfaces/IVaultParameters.sol';

import '../helpers/ReentrancyGuard.sol';
import '../helpers/SafeMath.sol';


/**
 * @title CDPManager01_Fallback
 **/
contract CDPManager01_Fallback is ReentrancyGuard {
  using SafeMath for uint;

  IVault public immutable vault;
  IVaultManagerParameters public immutable vaultManagerParameters;
  IOracleRegistry public immutable oracleRegistry;
  ICDPRegistry public immutable cdpRegistry;

  uint public constant Q112 = 2 ** 112;
  uint public constant DENOMINATOR_1E5 = 1e5;

  /**
   * @dev Trigger when joins are happened
  **/
  event Join(address indexed asset, address indexed owner, uint main, uint gcd);

  /**
   * @dev Trigger when exits are happened
  **/
  event Exit(address indexed asset, address indexed owner, uint main, uint gcd);

  /**
   * @dev Trigger when liquidations are initiated
  **/
  event LiquidationTriggered(address indexed asset, address indexed owner);

  modifier checkpoint(address asset, address owner) {
    _;
    cdpRegistry.checkpoint(asset, owner);
  }

  /**
   * @param _vaultManagerParameters The address of the contract with Vault manager parameters
   * @param _oracleRegistry The address of the oracle registry
   * @param _cdpRegistry The address of the CDP registry
   **/
  constructor(address _vaultManagerParameters, address _oracleRegistry, address _cdpRegistry) {
    require(
      _vaultManagerParameters != address(0) &&
      _oracleRegistry != address(0) &&
      _cdpRegistry != address(0),
      "GCD Protocol: INVALID_ARGS"
    );
    vaultManagerParameters = IVaultManagerParameters(_vaultManagerParameters);
    vault = IVault(IVaultParameters(IVaultManagerParameters(_vaultManagerParameters).vaultParameters()).vault());
    oracleRegistry = IOracleRegistry(_oracleRegistry);
    cdpRegistry = ICDPRegistry(_cdpRegistry);
  }

  /**
    * @notice Depositing tokens must be pre-approved to Vault address
    * @notice position actually considered as spawned only when debt > 0
    * @dev Deposits collateral and/or borrows GCD
    * @param asset The address of the collateral
    * @param assetAmount The amount of the collateral to deposit
    * @param gcdAmount The amount of GCD token to borrow
    **/
  function join(address asset, uint assetAmount, uint gcdAmount, KeydonixOracleAbstract.ProofDataStruct calldata proofData) public nonReentrant checkpoint(asset, msg.sender) {
    require(gcdAmount != 0 || assetAmount != 0, "GCD Protocol: USELESS_TX");

    require(IToken(asset).decimals() <= 18, "GCD Protocol: NOT_SUPPORTED_DECIMALS");

    if (gcdAmount == 0) {

      vault.depositMain(asset, msg.sender, assetAmount);

    } else {

      uint oracleType = _selectOracleType(asset);

      bool spawned = vault.debts(asset, msg.sender) != 0;

      if (!spawned) {
        // spawn a position
        vault.spawn(asset, msg.sender, oracleType);
      }

      if (assetAmount != 0) {
        vault.depositMain(asset, msg.sender, assetAmount);
      }

      // mint GCD to owner
      vault.borrow(asset, msg.sender, gcdAmount);

      // check collateralization
      _ensurePositionCollateralization(asset, msg.sender, proofData);

    }

    // fire an event
    emit Join(asset, msg.sender, assetAmount, gcdAmount);
  }

  /**
    * @notice Tx sender must have a sufficient GCD balance to pay the debt
    * @dev Withdraws collateral and repays specified amount of debt
    * @param asset The address of the collateral
    * @param assetAmount The amount of the collateral to withdraw
    * @param gcdAmount The amount of GCD to repay
    **/
  function exit(address asset, uint assetAmount, uint gcdAmount, KeydonixOracleAbstract.ProofDataStruct calldata proofData) public nonReentrant checkpoint(asset, msg.sender) returns (uint) {

    // check usefulness of tx
    require(assetAmount != 0 || gcdAmount != 0, "GCD Protocol: USELESS_TX");

    uint debt = vault.debts(asset, msg.sender);

    // catch full repayment
    if (gcdAmount > debt) { gcdAmount = debt; }

    if (assetAmount == 0) {
      _repay(asset, msg.sender, gcdAmount);
    } else {
      if (debt == gcdAmount) {
        vault.withdrawMain(asset, msg.sender, assetAmount);
        if (gcdAmount != 0) {
          _repay(asset, msg.sender, gcdAmount);
        }
      } else {
        // withdraw collateral to the owner address
        vault.withdrawMain(asset, msg.sender, assetAmount);

        if (gcdAmount != 0) {
          _repay(asset, msg.sender, gcdAmount);
        }

        vault.update(asset, msg.sender);

        _ensurePositionCollateralization(asset, msg.sender, proofData);
      }
    }

    // fire an event
    emit Exit(asset, msg.sender, assetAmount, gcdAmount);

    return gcdAmount;
  }

  /**
    * @notice Repayment is the sum of the principal and interest
    * @dev Withdraws collateral and repays specified amount of debt
    * @param asset The address of the collateral
    * @param assetAmount The amount of the collateral to withdraw
    * @param repayment The target repayment amount
    **/
  function exit_targetRepayment(address asset, uint assetAmount, uint repayment, KeydonixOracleAbstract.ProofDataStruct calldata proofData) external returns (uint) {

    uint gcdAmount = _calcPrincipal(asset, msg.sender, repayment);

    return exit(asset, assetAmount, gcdAmount, proofData);
  }

  // decreases debt
  function _repay(address asset, address owner, uint gcdAmount) internal {
    uint fee = vault.calculateFee(asset, owner, gcdAmount);
    vault.chargeFee(vault.gcd(), owner, fee);

    // burn GCD from the owner's balance
    uint debtAfter = vault.repay(asset, owner, gcdAmount);
    if (debtAfter == 0) {
      // clear unused storage
      vault.destroy(asset, owner);
    }
  }

  function _ensurePositionCollateralization(address asset, address owner, KeydonixOracleAbstract.ProofDataStruct calldata proofData) internal view {
    // collateral value of the position in USD
    uint usdValue_q112 = getCollateralUsdValue_q112(asset, owner, proofData);

    // USD limit of the position
    uint usdLimit = usdValue_q112 * vaultManagerParameters.initialCollateralRatio(asset) / Q112 / 100;

    // revert if collateralization is not enough
    require(vault.getTotalDebt(asset, owner) <= usdLimit, "GCD Protocol: UNDERCOLLATERALIZED");
  }

  // Liquidation Trigger

  /**
   * @dev Triggers liquidation of a position
   * @param asset The address of the collateral token of a position
   * @param owner The owner of the position
   **/
  function triggerLiquidation(address asset, address owner, KeydonixOracleAbstract.ProofDataStruct calldata proofData) external nonReentrant {

    // USD value of the collateral
    uint usdValue_q112 = getCollateralUsdValue_q112(asset, owner, proofData);

    // reverts if a position is not liquidatable
    require(_isLiquidatablePosition(asset, owner, usdValue_q112), "GCD Protocol: SAFE_POSITION");

    uint liquidationDiscount_q112 = usdValue_q112.mul(
      vaultManagerParameters.liquidationDiscount(asset)
    ).div(DENOMINATOR_1E5);

    uint initialLiquidationPrice = usdValue_q112.sub(liquidationDiscount_q112).div(Q112);

    // sends liquidation command to the Vault
    vault.triggerLiquidation(asset, owner, initialLiquidationPrice);

    // fire an liquidation event
    emit LiquidationTriggered(asset, owner);
  }

  function getCollateralUsdValue_q112(address asset, address owner, KeydonixOracleAbstract.ProofDataStruct calldata proofData) public view returns (uint) {
    uint oracleType = _selectOracleType(asset);
    return KeydonixOracleAbstract(oracleRegistry.oracleByType(oracleType)).assetToUsd(asset, vault.collaterals(asset, owner), proofData);
  }

  /**
   * @dev Determines whether a position is liquidatable
   * @param asset The address of the collateral
   * @param owner The owner of the position
   * @param usdValue_q112 Q112-encoded USD value of the collateral
   * @return boolean value, whether a position is liquidatable
   **/
  function _isLiquidatablePosition(
    address asset,
    address owner,
    uint usdValue_q112
  ) internal view returns (bool) {
    uint debt = vault.getTotalDebt(asset, owner);

    // position is collateralized if there is no debt
    if (debt == 0) return false;

    return debt.mul(100).mul(Q112).div(usdValue_q112) >= vaultManagerParameters.liquidationRatio(asset);
  }

  function _selectOracleType(address asset) internal view returns (uint oracleType) {
    oracleType = _getOracleType(asset);
    require(oracleType != 0, "GCD Protocol: INVALID_ORACLE_TYPE");
    address oracle = oracleRegistry.oracleByType(oracleType);
    require(oracle != address(0), "GCD Protocol: DISABLED_ORACLE");
  }

  /**
   * @dev Determines whether a position is liquidatable
   * @param asset The address of the collateral
   * @param owner The owner of the position
   * @return boolean value, whether a position is liquidatable
   **/
  function isLiquidatablePosition(
    address asset,
    address owner,
    KeydonixOracleAbstract.ProofDataStruct calldata proofData
  ) external view returns (bool) {

    uint usdValue_q112 = getCollateralUsdValue_q112(asset, owner, proofData);

    return _isLiquidatablePosition(asset, owner, usdValue_q112);
  }

  /**
   * @dev Calculates current utilization ratio
   * @param asset The address of the collateral
   * @param owner The owner of the position
   * @return utilization ratio
   **/
  function utilizationRatio(
    address asset,
    address owner,
    KeydonixOracleAbstract.ProofDataStruct calldata proofData
  ) public view returns (uint) {
    uint debt = vault.getTotalDebt(asset, owner);
    if (debt == 0) return uint(0);

    uint usdValue_q112 = getCollateralUsdValue_q112(asset, owner, proofData);

    return debt.mul(100).mul(Q112).div(usdValue_q112);
  }


  /**
   * @dev Calculates liquidation price
   * @param asset The address of the collateral
   * @param owner The owner of the position
   * @return Q112-encoded liquidation price
   **/
  function liquidationPrice_q112(
    address asset,
    address owner
  ) external view returns (uint) {
    uint debt = vault.getTotalDebt(asset, owner);
    if (debt == 0) return uint(-1);

    uint collateralLiqPrice = debt.mul(100).mul(Q112).div(vaultManagerParameters.liquidationRatio(asset));

    require(IToken(asset).decimals() <= 18, "GCD Protocol: NOT_SUPPORTED_DECIMALS");

    return collateralLiqPrice / vault.collaterals(asset, owner) / 10 ** (18 - IToken(asset).decimals());
  }

  function _calcPrincipal(address asset, address owner, uint repayment) internal view returns (uint) {
    uint fee = vault.stabilityFee(asset, owner) * (block.timestamp - vault.lastUpdate(asset, owner)) / 365 days;
    return repayment * DENOMINATOR_1E5 / (DENOMINATOR_1E5 + fee);
  }

  function _getOracleType(address asset) internal view returns (uint) {
    uint[] memory keydonixOracleTypes = oracleRegistry.getKeydonixOracleTypes();
    for (uint i = 0; i < keydonixOracleTypes.length; i++) {
      if (IVaultParameters(vaultManagerParameters.vaultParameters()).isOracleTypeEnabled(keydonixOracleTypes[i], asset)) {
        return keydonixOracleTypes[i];
      }
    }
    revert("GCD Protocol: NO_ORACLE_FOUND");
  }
}
