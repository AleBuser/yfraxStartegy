import pytest
from brownie import config, Wei


@pytest.fixture
def gov(accounts):
    # yearn multis... I mean YFI governance. I swear!
    yield accounts[1]


@pytest.fixture
def rewards(gov):
    yield gov  # TODO: Add rewards contract


@pytest.fixture
def guardian(accounts):
    # YFI Whale, probably
    yield accounts[2]


@pytest.fixture
def proxyFactoryInitializable(accounts, ProxyFactoryInitializable):
    yield accounts[0].deploy(ProxyFactoryInitializable)


@pytest.fixture(
    params=[
        "USDC",
    ]
)
def token(Token, request):
    tokens = {
        "USDC": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    }
    yield Token.at(tokens[request.param])


@pytest.fixture
def fraxToken(Token):
    yield Token.at("0x853d955aCEf822Db058eb8505911ED77F175b99e")


@pytest.fixture
def fxsToken(Token):
    yield Token.at("0x3432b6a60d23ca0dfca7761b7ab56459d9c964d0")


@pytest.fixture
def aprDeposit(token):
    aprDeposits = {
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48": 5 * 1e5,
    }
    yield aprDeposits[token.address]


@pytest.fixture
def tokenWhale(accounts, Contract, token):
    tokenWhalesAndQuantities = {
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48": {
            "whale": "0xf977814e90da44bfa03b6295a0616a897441acec",  # binance
            "quantity": 1 * 1e6,
        }
    }

    user = accounts[5]
    tokenWhaleAndQuantity = tokenWhalesAndQuantities[token.address]

    whale = accounts.at(tokenWhaleAndQuantity["whale"], force=True)
    bal = tokenWhaleAndQuantity["quantity"] * 10 ** token.decimals()
    token.transfer(user, bal, {"from": whale})

    yield user


@pytest.fixture
def vault(pm, gov, rewards, guardian, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "")
    yield vault


@pytest.fixture
def user(accounts):
    yield accounts[5]


@pytest.fixture
def strategist(accounts):
    # You! Our new Strategist!
    yield accounts[3]


@pytest.fixture
def keeper(accounts):
    # This is our trusty bot!
    yield accounts[4]


@pytest.fixture()
def strategy(vault, strategyFactory):
    yield strategyFactory(vault)


@pytest.fixture()
def strategyFactory(
    strategist,
    keeper,
    proxyFactoryInitializable,
    fraxToken,
    fxsToken,
    StrategyFrax,
):
    def factory(vault, proxy=True):
        onBehalfOf = strategist
        weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
        stakingContract = "0xa29367a3f057F3191b62bd4055845a33411892b6"
        uniswapLP = "0x97C4adc5d28A86f9470C70DD91Dc6CC2f20d2d4D"
        uniswapRouterV2 = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"
        usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"

        fraxOracle = "0xD18660Ab8d4eF5bE062652133fe4348e0cB996DA"
        fxsOracle = "0x9e483C76D7a66F7E1feeBEAb54c349Df2F00eBdE"

        strategyLogic = StrategyFrax.deploy(
            vault,
            weth,
            stakingContract,
            fxsToken,
            fraxToken,
            usdc,
            fraxOracle,
            fxsOracle,
            uniswapLP,
            uniswapRouterV2,
            {"from": strategist},
        )

        strategyAddress = strategyLogic.address

        if proxy:
            data = strategyLogic.init.encode_input(
                vault,
                onBehalfOf,
                weth,
                stakingContract,
                fxsToken,
                fraxToken,
                usdc,
                fraxOracle,
                fxsOracle,
                uniswapLP,
                uniswapRouterV2,
            )
            tx = proxyFactoryInitializable.deployMinimal(
                strategyLogic, data, {"from": strategist}
            )

            strategyAddress = tx.events["ProxyCreated"]["proxy"]

        strategy = StrategyFrax.at(strategyAddress, owner=strategist)
        strategy.setKeeper(keeper)
        return strategy

    yield factory