import { ethers } from "hardhat"
import { BigNumber, Contract } from "ethers"
import { Fixture } from "ethereum-waffle"
import { getFactory } from "./utils";

import { Bounding } from "../../typechain/Bounding"
import { WETH9 } from "../../typechain/WETH9"
import { ERC20 } from "../../typechain/ERC20"
import { TestAggregator } from "../../typechain/TestAggregator"
import { TestCan } from "../../typechain/TestCan"

import { CompoundStaking__factory as compoundMeta } from "../../gton-farms-evm/types/factories/CompoundStaking__factory"
import { CompoundStaking } from "../../gton-farms-evm/types/CompoundStaking"

interface TokensFixture {
    weth: WETH9,
    gton: ERC20
    token0: ERC20,
    token1: ERC20
}

async function tokensFixture(): Promise<TokensFixture> {
    const factory = await ethers.getContractFactory("ERC20");
    const factoryWeth = await ethers.getContractFactory("WETH9");
    const gton = (await factory.deploy(BigNumber.from(2).pow(255))) as ERC20
    const token0 = (await factory.deploy(BigNumber.from(2).pow(255))) as ERC20
    const token1 = (await factory.deploy(BigNumber.from(2).pow(255))) as ERC20
    const weth = (await factoryWeth.deploy()) as WETH9

    return { weth, gton, token0, token1 }
}

interface Boundingfixture extends TokensFixture {
    bounding: Bounding
    compound: CompoundStaking
    token0Agg: TestAggregator
    gtonAgg: TestAggregator
    wethAgg: TestAggregator
    token1Agg: TestAggregator
    wethCan: TestCan
    token0Can: TestCan
    token1Can: TestCan
}

export const boundingFixture: Fixture<Boundingfixture> = async function ([
    wallet, treasury, admin0, admin1
]): Promise<Boundingfixture> {
    const { weth, token0, token1, gton } = await tokensFixture()
    const aggFactory = await ethers.getContractFactory("TestAggregator");
    const token0Agg = (await aggFactory.deploy(8, 50000000)) as TestAggregator
    const token1Agg = (await aggFactory.deploy(8, 25400000)) as TestAggregator
    const gtonAgg = (await aggFactory.deploy(8, 1000000000)) as TestAggregator
    const wethAgg = (await aggFactory.deploy(8, 1000000000)) as TestAggregator
    const canFactory = await ethers.getContractFactory("TestCan")
    const token0Can = (await canFactory.deploy(token0.address)) as TestCan;
    const token1Can = (await canFactory.deploy(token1.address)) as TestCan;
    const wethCan = (await canFactory.deploy(weth.address)) as TestCan;
    const libFactory = await ethers.getContractFactory("AddressArrayLib")
    const lib = await libFactory.deploy();
    const compoundF = new compoundMeta({ "__$fe4bb86d0d47fb102a6badbbe029860ef4$__": lib.address }, wallet);
    const compound = await compoundF.deploy(gton.address, BigNumber.from("150000"), "sGTON", "sGTON", 250, 15)
    const bounfingF = await ethers.getContractFactory("Bounding", {
        libraries: {
            AddressArrayLib: lib.address,
        }
    });
    const bounding = (await bounfingF.deploy(
        weth.address, 
        gton.address, 
        compound.address, 
        gtonAgg.address, 
        treasury.address, 
        [admin0.address, admin1.address],
        BigNumber.from("100000000000"),
        )) as Bounding

    return {
        weth,
        token0,
        token1,
        gton,
        token0Agg,
        token1Agg,
        wethAgg,
        bounding,
        gtonAgg,
        wethCan,
        compound,
        token0Can,
        token1Can
    }
}

