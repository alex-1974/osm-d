/**
 * Checked integer arithmetic used by codecs and coordinate decoding.
 *
 * The functions in this module never rely on overflowing an integer value.
 * They return `false` when the requested operation is not representable in
 * the result type and leave no partially computed value behind.
 */
module osm.util.checked;

/// Add two signed 64-bit values without overflowing.
bool checkedAdd(long a, long b, out long result) @safe pure nothrow @nogc
{
    if (b > 0 && a > long.max - b)
        return false;
    if (b < 0 && a < long.min - b)
        return false;

    result = a + b;
    return true;
}

/// Subtract two signed 64-bit values without overflowing.
bool checkedSub(long a, long b, out long result) @safe pure nothrow @nogc
{
    if (b > 0 && a < long.min + b)
        return false;
    if (b < 0 && a > long.max + b)
        return false;

    result = a - b;
    return true;
}

/// Multiply two signed 64-bit values without overflowing.
bool checkedMul(long a, long b, out long result) @safe pure nothrow @nogc
{
    if (a == 0 || b == 0)
    {
        result = 0;
        return true;
    }

    // The only division-based overflow check that would itself be invalid.
    if ((a == long.min && b == -1) || (b == long.min && a == -1))
        return false;

    if (a > 0)
    {
        if (b > 0)
        {
            if (a > long.max / b)
                return false;
        }
        else
        {
            if (b < long.min / a)
                return false;
        }
    }
    else
    {
        if (b > 0)
        {
            if (a < long.min / b)
                return false;
        }
        else
        {
            // Both operands are negative. long.min / negative is positive.
            if (a < long.max / b)
                return false;
        }
    }

    result = a * b;
    return true;
}

/// Compute `base + factor * value` without overflowing.
bool checkedMulAdd(long base, long factor, long value, out long result)
    @safe pure nothrow @nogc
{
    long product;
    if (!checkedMul(factor, value, product))
        return false;
    return checkedAdd(base, product, result);
}

unittest
{
    long value;

    assert(checkedAdd(2, 3, value) && value == 5);
    assert(!checkedAdd(long.max, 1, value));
    assert(!checkedAdd(long.min, -1, value));

    assert(checkedSub(7, 5, value) && value == 2);
    assert(!checkedSub(long.min, 1, value));
    assert(!checkedSub(long.max, -1, value));

    assert(checkedMul(7, -6, value) && value == -42);
    assert(checkedMul(long.min, 1, value) && value == long.min);
    assert(!checkedMul(long.min, -1, value));
    assert(!checkedMul(long.max, 2, value));

    assert(checkedMulAdd(5, 100, -2, value) && value == -195);
    assert(!checkedMulAdd(long.max, 2, 1, value));
}
