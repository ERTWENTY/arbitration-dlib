var Token = artifacts.require("./lib/bokkypoobah/Token.sol")
var MMInstantiator = artifacts.require("./MMInstantiator.sol");
var SimpleMemoryLib = artifacts.require("./SimpleMemoryLib.sol");
var SimpleMemoryInstantiator = artifacts.require("./SimpleMemoryInstantiator.sol");
var SubleqLib = artifacts.require("./SubleqLib.sol");
var SubleqInterface = artifacts.require("./SubleqInterface.sol");
var PartitionInstantiator = artifacts.require("./PartitionInstantiator.sol");
var DepthLib = artifacts.require("./DepthLib.sol");
var DepthInterface = artifacts.require("./DepthInterface.sol");
var VGInstantiator = artifacts.require("./VGInstantiator.sol");

module.exports = function(deployer) {
  deployer.deploy(MMInstantiator);
  deployer.deploy(SimpleMemoryInstantiator);
  deployer.deploy(SubleqLib);
  deployer.link(SubleqLib, SubleqInterface);
  deployer.deploy(PartitionInstantiator);
  deployer.deploy(DepthLib);
  deployer.link(DepthLib, DepthInterface);
  deployer.link(SubleqLib, VGInstantiator);
};
