using System.Diagnostics.CodeAnalysis;
using System.Globalization;

namespace GitWolf.Core;

/// <summary>
/// A dotted version such as <c>1.4.0</c> or <c>v2.0.0-beta.1</c>. Pre-releases sort before their release.
/// Ported from AppVersion.swift.
/// </summary>
public sealed class AppVersion : IComparable<AppVersion>, IEquatable<AppVersion>
{
    private readonly int[] _numbers;

    private AppVersion(int[] numbers, string? prerelease) => (_numbers, Prerelease) = (numbers, prerelease);

    public IReadOnlyList<int> Numbers => _numbers;
    public string? Prerelease { get; }

    /// <summary>The number macOS's feed compares: 1.2.3 becomes 1002003.</summary>
    public long BuildNumber => Number(0) * 1_000_000L + Number(1) * 1_000L + Number(2);

    public static bool TryParse(string? text, [NotNullWhen(true)] out AppVersion? version)
    {
        version = null;
        var s = (text ?? "").Trim();
        if (s.StartsWith('v') || s.StartsWith('V')) s = s[1..];
        var parts = s.Split('-', 2);
        var core = parts[0].Split('.');
        var numbers = new int[core.Length];
        for (var i = 0; i < core.Length; i++)
            if (!int.TryParse(core[i], NumberStyles.None, CultureInfo.InvariantCulture, out numbers[i])) return false;
        version = new AppVersion(numbers, parts.Length > 1 ? parts[1] : null);
        return true;
    }

    public override string ToString() =>
        string.Join('.', _numbers) + (Prerelease is null ? "" : "-" + Prerelease);

    private int Number(int index) => index < _numbers.Length ? _numbers[index] : 0;

    public int CompareTo(AppVersion? other)
    {
        if (other is null) return 1;
        for (var i = 0; i < Math.Max(_numbers.Length, other._numbers.Length); i++)
            if (Number(i) != other.Number(i)) return Number(i).CompareTo(other.Number(i));
        return (Prerelease, other.Prerelease) switch
        {
            (null, null) => 0,
            (null, _) => 1,
            (_, null) => -1,
            ({ } a, { } b) => CompareNumeric(a, b),
        };
    }

    /// <summary>Text order, except that runs of digits compare as numbers: beta.2 before beta.10.</summary>
    private static int CompareNumeric(string a, string b)
    {
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsAsciiDigit(a[i]) && char.IsAsciiDigit(b[j]))
            {
                var x = Digits(a, ref i);
                var y = Digits(b, ref j);
                var order = x.Length != y.Length ? x.Length.CompareTo(y.Length) : string.CompareOrdinal(x, y);
                if (order != 0) return order;
            }
            else
            {
                var order = a[i++].CompareTo(b[j++]);
                if (order != 0) return order;
            }
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }

    private static string Digits(string s, ref int at)
    {
        var start = at;
        while (at < s.Length && char.IsAsciiDigit(s[at])) at++;
        return s[start..at].TrimStart('0');
    }

    /// <summary><c>2.0</c> equals <c>2.0.0</c>.</summary>
    public bool Equals(AppVersion? other) => other is not null && CompareTo(other) == 0;

    public override bool Equals(object? obj) => Equals(obj as AppVersion);

    public override int GetHashCode()
    {
        var length = _numbers.Length;
        while (length > 0 && _numbers[length - 1] == 0) length--;
        var hash = new HashCode();
        for (var i = 0; i < length; i++) hash.Add(_numbers[i]);
        return hash.ToHashCode();
    }

    public static bool operator <(AppVersion a, AppVersion b) => a.CompareTo(b) < 0;
    public static bool operator >(AppVersion a, AppVersion b) => a.CompareTo(b) > 0;
}
