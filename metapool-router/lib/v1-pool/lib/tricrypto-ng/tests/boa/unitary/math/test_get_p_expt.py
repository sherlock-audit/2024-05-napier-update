import math
from decimal import Decimal

import boa
import pytest
from boa.test import strategy
from hypothesis import given, settings

from tests.boa.fixtures.pool import INITIAL_PRICES
from tests.boa.utils.tokens import mint_for_testing

SETTINGS = {"max_examples": 1000, "deadline": None}
PRECISION_THRESHOLD = 1e-5


def approx(x1, x2, precision=PRECISION_THRESHOLD):
    return abs(math.log(x1 / x2)) <= precision


def assert_string_contains(string, substrings):
    assert any(substring in string for substring in substrings)


# flake8: noqa: E501
@pytest.fixture(scope="module")
def _dydx_optimised_math():

    get_price_impl = """
N_COINS: constant(uint256) = 3
A_MULTIPLIER: constant(int256) = 10000

@external
@view
def get_p(
    _xp: uint256[N_COINS], _D: uint256, _A_gamma: uint256[N_COINS-1]
) -> int256[N_COINS-1]:

    D: int256 = convert(_D, int256)
    ANN: int256 = convert(_A_gamma[0], int256)
    gamma: int256 = convert(_A_gamma[1], int256)
    x: int256 = convert(_xp[0], int256)
    y: int256 = convert(_xp[1], int256)
    z: int256 = convert(_xp[2], int256)

    NN_A_gamma2: int256 = 27 * ANN * gamma**2
    S: int256 = x + y + z
    K: int256 = 27 * x * y / D * z / D * 10**36 / D
    G: int256 = (
        3 * K**2 / 10**36
        - K * (4 * gamma * 10**18 + 6 * 10**36) / 10**36
        + NN_A_gamma2 * (S - D) / D / 27 / A_MULTIPLIER
        + (gamma + 10**18) * (gamma +  3 * 10**18)
    )

    G3: int256 = G * D * 27 * 10000 / NN_A_gamma2
    return [
        x * (G3 + y) / y * 10**18 / (G3 + x),
        x * (G3 + z) / z * 10**18 / (G3 + x),
    ]
"""
    return boa.loads(get_price_impl, name="Optimised")


# flake8: noqa: E501
@pytest.fixture(scope="module")
def dydx_optimised_math():

    get_price_impl = """
N_COINS: constant(uint256) = 3
A_MULTIPLIER: constant(uint256) = 10000

@external
@view
def get_p(
    _xp: uint256[N_COINS], _D: uint256, _A_gamma: uint256[N_COINS-1]
) -> uint256[N_COINS-1]:

    K0: uint256 = unsafe_div(
        unsafe_div(unsafe_div(27 * _xp[0] * _xp[1], _D) * _xp[2], _D) * 10**36,
        _D
    )
    GK0: uint256 = (
        unsafe_div(unsafe_div(2 * K0 * K0, 10**36) * K0, 10**36)
        + pow_mod256(unsafe_add(_A_gamma[1], 10**18), 2)
        - unsafe_div(
            unsafe_div(pow_mod256(K0, 2), 10**36) * unsafe_add(unsafe_mul(2, _A_gamma[1]), 3 * 10**18),
            10**18
        )
    )
    NNAG2: uint256 = unsafe_div(unsafe_mul(_A_gamma[0], pow_mod256(_A_gamma[1], 2)), A_MULTIPLIER)
    denominator: uint256 = (GK0 + unsafe_div(unsafe_div(NNAG2 * _xp[0], _D) * K0, 10**36) )

    p: uint256[N_COINS-1] = [
        unsafe_div(_xp[0] * (GK0 + unsafe_div(unsafe_div(NNAG2 * _xp[1], _D) * K0, 10**36) ) / _xp[1] * 10**18, denominator),
        unsafe_div(_xp[0] * (GK0 + unsafe_div(unsafe_div(NNAG2 * _xp[2], _D) * K0, 10**36) ) / _xp[2] * 10**18, denominator),
    ]
    return p
"""
    return boa.loads(get_price_impl, name="Optimised")


def get_p_decimal(X, D, ANN, gamma):

    X = [Decimal(_) for _ in X]
    P = 10**18 * X[0] * X[1] * X[2]
    N = len(X)
    D = Decimal(D)

    A = ANN / N**N / 10000

    x = X[0]
    y = X[1]
    z = X[2]

    _K0 = 27 * x * y / D * z / D * 10**36 / D
    _GK0 = (
        2 * _K0 * _K0 / 10**36 * _K0 / 10**36
        + (gamma + 10**18) ** 2
        - (_K0 * _K0 / 10**36 * (2 * gamma + 3 * 10**18) / 10**18)
    )
    _NNAG2 = Decimal(N**N * A * gamma**2)
    _denominator = _GK0 + _NNAG2 * x / D * _K0 / 10**36
    _p = [
        int(
            x
            * (_GK0 + _NNAG2 * y / D * _K0 / 10**36)
            / y
            * 10**18
            / _denominator
        ),
        int(
            x
            * (_GK0 + _NNAG2 * z / D * _K0 / 10**36)
            / z
            * 10**18
            / _denominator
        ),
    ]

    return _p


def _check_p(a, b):

    assert a > 0
    assert b > 0

    if abs(a - b) <= 1:
        return True

    return approx(a, b)


def _get_prices_vyper(swap, price_calc):

    A = swap.A()
    gamma = swap.gamma()
    xp = swap.internal.xp()
    D = swap.D()

    p = price_calc.get_p(xp, D, [A, gamma])

    price_token_1_wrt_0 = p[0]
    price_token_2_wrt_0 = p[1]

    prices = [
        price_token_1_wrt_0 * swap.price_scale(0) // 10**18,
        price_token_2_wrt_0 * swap.price_scale(1) // 10**18,
    ]

    return prices


def _get_prices_numeric_nofee(swap, views, sell_usd):

    if sell_usd:

        dx = 10**16  # 0.01 USD
        dy = [
            views.internal._get_dy_nofee(0, 1, dx, swap)[0],
            views.internal._get_dy_nofee(0, 2, dx, swap)[0],
        ]
        prices = [dx * 10**18 // dy[0], dx * 10**18 // dy[1]]

    else:

        prices = []
        for i in range(1, 3):

            dx = int(0.01 * 10**36 // INITIAL_PRICES[i])
            dolla_out = views.internal._get_dy_nofee(i, 0, dx, swap)[0]
            prices.append(dolla_out * 10**18 // dx)

    return prices


# ----- Tests -----


def test_against_expt(dydx_optimised_math):

    ANN = 42253659
    gamma = 11720394944313222
    xp = [
        165898964704801767090,
        180089627760498533741,
        479703029155498241214,
    ]
    D = 798348646635793903194
    p = [950539494815349606, 589388920722357662]

    # test python implementation:
    output_python = get_p_decimal(xp, D, ANN, gamma)
    assert _check_p(output_python[0], p[0])
    assert _check_p(output_python[1], p[1])

    # test vyper implementation
    output_vyper = dydx_optimised_math.get_p(xp, D, [ANN, gamma])

    assert _check_p(output_vyper[0], p[0])
    assert _check_p(output_vyper[1], p[1])


def _imbalance_swap(swap, coins, imbalance_frac, user, dollar_amount, i, j):

    # make swap imbalanced:
    mint_for_testing(coins[0], user, int(swap.balances(0) * imbalance_frac))

    try:
        with boa.env.prank(user):
            swap.exchange(i, j, coins[0].balanceOf(user), 0)
    except boa.BoaError as b_error:
        assert_string_contains(
            b_error.stack_trace.last_frame.pretty_vm_reason,
            ["Unsafe value for y", "Unsafe values x[i]"],
        )
        return

    dx = dollar_amount * 10**36 // INITIAL_PRICES[i]
    mint_for_testing(coins[i], user, dx)

    try:
        with boa.env.prank(user):
            swap.exchange(i, j, dx, 0)
    except boa.BoaError as b_error:
        assert_string_contains(
            b_error.stack_trace.last_frame.pretty_vm_reason,
            ["Unsafe value for y", "Unsafe values x[i]"],
        )
        return

    return swap


@given(
    dollar_amount=strategy(
        "uint256", min_value=5 * 10**4, max_value=5 * 10**8
    ),
    imbalance_frac=strategy("decimal", min_value=0.1, max_value=0.7),
)
@settings(**SETTINGS)
@pytest.mark.parametrize("i", [0, 1, 2])
@pytest.mark.parametrize("j", [0, 1, 2])
def test_dxdy_similar(
    swap_with_deposit,
    dydx_optimised_math,
    views_contract,
    user,
    dollar_amount,
    imbalance_frac,
    coins,
    i,
    j,
):

    if i == j:
        return

    # make swap imbalanced:
    swap_with_deposit = _imbalance_swap(
        swap_with_deposit, coins, imbalance_frac, user, dollar_amount, i, j
    )
    if not swap_with_deposit:
        return

    dxdy_vyper = _get_prices_vyper(swap_with_deposit, dydx_optimised_math)
    dxdy_numeric_nofee = _get_prices_numeric_nofee(
        swap_with_deposit, views_contract, sell_usd=(i == 0)
    )

    for n in range(2):

        assert approx(dxdy_vyper[n], dxdy_numeric_nofee[n])

        dxdy_swap = swap_with_deposit.last_prices(
            n
        )  # <-- we check unsafe impl here.
        assert approx(dxdy_vyper[n], dxdy_swap)


@given(
    dollar_amount=strategy(
        "uint256", min_value=10**4, max_value=4 * 10**5
    ),
    imbalance_frac=strategy("decimal", min_value=0.1, max_value=0.7),
)
@settings(**SETTINGS)
@pytest.mark.parametrize("j", [1, 2])
def test_dxdy_pump(
    swap_with_deposit,
    dydx_optimised_math,
    user,
    dollar_amount,
    imbalance_frac,
    coins,
    j,
):

    dxdy_math_0 = _get_prices_vyper(swap_with_deposit, dydx_optimised_math)
    dxdy_swap_0 = [
        swap_with_deposit.last_prices(0),
        swap_with_deposit.last_prices(1),
    ]

    swap_with_deposit = _imbalance_swap(
        swap_with_deposit, coins, imbalance_frac, user, dollar_amount, 0, j
    )
    if not swap_with_deposit:
        return

    dxdy_math_1 = _get_prices_vyper(swap_with_deposit, dydx_optimised_math)
    dxdy_swap_1 = [
        swap_with_deposit.last_prices(0),
        swap_with_deposit.last_prices(1),
    ]

    for n in range(2):
        assert dxdy_math_1[n] > dxdy_math_0[n]
        assert dxdy_swap_1[n] > dxdy_swap_0[n]


@given(
    dollar_amount=strategy(
        "uint256", min_value=10**4, max_value=4 * 10**5
    ),
    imbalance_frac=strategy("decimal", min_value=0.1, max_value=0.7),
)
@settings(**SETTINGS)
@pytest.mark.parametrize("j", [1, 2])
def test_dxdy_dump(
    swap_with_deposit,
    dydx_optimised_math,
    user,
    dollar_amount,
    imbalance_frac,
    coins,
    j,
):

    dxdy_math_0 = _get_prices_vyper(swap_with_deposit, dydx_optimised_math)
    dxdy_swap_0 = [
        swap_with_deposit.last_prices(0),
        swap_with_deposit.last_prices(1),
    ]

    swap_with_deposit = _imbalance_swap(
        swap_with_deposit, coins, imbalance_frac, user, dollar_amount, j, 0
    )
    if not swap_with_deposit:
        return

    dxdy_math_1 = _get_prices_vyper(swap_with_deposit, dydx_optimised_math)
    dxdy_swap_1 = [
        swap_with_deposit.last_prices(0),
        swap_with_deposit.last_prices(1),
    ]

    for n in range(2):
        assert dxdy_math_1[n] < dxdy_math_0[n]
        assert dxdy_swap_1[n] < dxdy_swap_0[n]
