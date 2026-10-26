import Foundation

/// The categories used by the calculator function catalogue. `allCases`
/// drives the category picker in `CalculatorFunctionCatalogView`.
enum CalculatorFunctionCategory: String, CaseIterable, Identifiable, Sendable {
    case session = "session"
    case arithmetic = "arithmetic"
    case algebra = "algebra"
    case calculus = "calculus"
    case trigonometry = "trigonometry"
    case matrices = "matrices"
    case lists = "lists"
    case numbers = "numbers"
    case complex = "complex"

    var id: String { rawValue }

    /// Human-readable name shown in the picker and the detail pane.
    var displayName: String {
        switch self {
        case .session: return "Home screen"
        case .arithmetic: return "Arithmetic"
        case .algebra: return "Algebra"
        case .calculus: return "Calculus"
        case .trigonometry: return "Trigonometry"
        case .matrices: return "Matrices"
        case .lists: return "Lists"
        case .numbers: return "Numbers"
        case .complex: return "Complex"
        }
    }
}

/// How well one catalogue entry is known to work with the bundled CAS
/// helper. The labels matter: this app runs a CAS with TI-89 style input,
/// not a complete TI-89, and the catalogue must not claim more than that.
enum CalculatorFunctionCompatibility: Hashable, Sendable {
    /// The example was evaluated against the bundled helper and produced
    /// a real result.
    case verified
    /// The TI spelling is accepted because the input layer (`TISyntax`)
    /// maps it to the engine's own command name. The example was also
    /// evaluated against the helper.
    case alias
    /// A known gap. The example either errors or comes back unevaluated.
    /// The entry's description states the cautions.
    case notYetVerified

    /// Short label shown in the list and detail pane.
    var label: String {
        switch self {
        case .verified: return "Verified"
        case .alias: return "Alias"
        case .notYetVerified: return "Not yet verified"
        }
    }

    /// One-line explanation shown in the detail pane.
    var detail: String {
        switch self {
        case .verified:
            return "The example was checked against the CAS helper and produced the described result."
        case .alias:
            return "The TI spelling works because the input layer maps it to the engine's own command name. The example was checked against the CAS helper."
        case .notYetVerified:
            return "Known gap. The example errors or comes back unevaluated. Read the notes before you rely on it."
        }
    }
}

/// One function or operation in the calculator's TI-89 style guide.
struct CalculatorFunctionGuide: Identifiable, Hashable, Sendable {
    /// Stable, unique identifier (used by the sheet's list selection).
    let id: String
    /// Short name shown in the list, e.g. "solve(".
    let title: String
    let category: CalculatorFunctionCategory
    /// The syntax pattern, e.g. "solve(equation, var)".
    let syntax: String
    /// What it does, plus cautions. Simple, factual prose.
    let description: String
    /// One complete entry line that can be evaluated as typed.
    let example: String
    let compatibility: CalculatorFunctionCompatibility

    init(id: String,
         title: String,
         category: CalculatorFunctionCategory,
         syntax: String,
         description: String,
         example: String,
         compatibility: CalculatorFunctionCompatibility) {
        self.id = id
        self.title = title
        self.category = category
        self.syntax = syntax
        self.description = description
        self.example = example
        self.compatibility = compatibility
    }
}

/// Curated catalogue of TI-89 style functions the calculator supports or
/// documents. Scope note kept honest on purpose:
///
/// - `verified` and `alias` examples were all run through the real
///   `typstedit-cas` helper (TI preprocessing included) and produced the
///   described results.
/// - `notYetVerified` entries are known gaps; their examples error or stay
///   unevaluated, and each entry says so.
/// - The engine is a CAS with TI-89 style input. It is not a full TI-89:
///   there is no programming, no arbitrary code execution, no file or
///   network access from the entry line.
enum CalculatorFunctionCatalog {

    /// The curated entries, grouped by category.
    static let entries: [CalculatorFunctionGuide] = [
        // MARK: Home screen

        CalculatorFunctionGuide(
            id: "store",
            title: "Store (→)",
            category: .session,
            syntax: "value→name",
            description: "Stores a value in a variable. Type 5→a or 5->a. The example returns 5, and a*2 then gives 10. Variables stay stored until you forget them with delVar(name).",
            example: "5→a",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "recall",
            title: "Recall (ans, entry)",
            category: .session,
            syntax: "ans · ans(n) · entry(n)",
            description: "ans is the last result. ans(n) is the nth result back, and entry(n) is the nth input back; numbering starts at 1 for the newest line. Evaluate something first, for example 2+2, then use ans*2.",
            example: "ans*2",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "define",
            title: "Define a function",
            category: .session,
            syntax: "Define f(x)=expression",
            description: "Defines a function you can call afterwards. The echo prints like program text, but the function is set: f(3) returns 9. The input layer converts Define to the engine's := assignment.",
            example: "Define f(x)=x^2",
            compatibility: .alias),

        // MARK: Arithmetic

        CalculatorFunctionGuide(
            id: "operators",
            title: "Arithmetic (+ − × ÷)",
            category: .arithmetic,
            syntax: "+  -  *  /  ^",
            description: "Standard arithmetic with normal precedence. Powers use ^. abs(x) gives the absolute value (abs(-7) → 7), and n! gives the factorial (5! → 120).",
            example: "2+3*4",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "powers-roots",
            title: "Powers and roots",
            category: .arithmetic,
            syntax: "x^n · √(x) · x^(1/n)",
            description: "√( gives the square root: √(49) → 7. Other roots use x^(1/n): 9^(1/2) → 3. Roots of negative numbers follow the complex principal root, like the TI-89 in AUTO mode: √(-4) → 2*i.",
            example: "√(49)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "approx-exact",
            title: "approx( and exact(",
            category: .arithmetic,
            syntax: "approx(expr) · exact(number)",
            description: "approx( forces a decimal value: approx(√(2)) → 1.41421356237. exact( turns a decimal into a fraction: exact(0.5) → 1/2. Option-Return (⌥↩) forces a decimal for the whole line, like the TI's ◆ENTER.",
            example: "approx(√(2))",
            compatibility: .verified),

        // MARK: Algebra

        CalculatorFunctionGuide(
            id: "solve",
            title: "solve(",
            category: .algebra,
            syntax: "solve(equation, var)",
            description: "Exact solutions: solve(x^2-4=0,x) → (x=-2) or (x=2). Systems work too: solve({x+y=3,x-y=1},{x,y}) → (x=2) and (y=1). Add a condition with |, for example solve(x^2=4,x) | x>0 → (x=2).",
            example: "solve(x^2-4=0,x)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "csolve",
            title: "cSolve(",
            category: .algebra,
            syntax: "cSolve(equation, var)",
            description: "Solutions over the complex numbers: cSolve(x^2+1=0,x) → (x=i) or (x=-i). The input layer maps the TI spelling cSolve to the engine's csolve.",
            example: "cSolve(x^2+1=0,x)",
            compatibility: .alias),

        CalculatorFunctionGuide(
            id: "zeros",
            title: "zeros( and cZeros(",
            category: .algebra,
            syntax: "zeros(expr, var)",
            description: "zeros(x^2-4,x) → [2,-2]. cZeros( gives complex zeros: cZeros(x^2+1,x) → [-i,i].",
            example: "zeros(x^2-4,x)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "factor",
            title: "factor(",
            category: .algebra,
            syntax: "factor(expr[, var])",
            description: "Factors an expression: factor(x^2-4) → (x-2)*(x+2). For an integer's prime factors use ifactor( instead — factor(12) returns 12 here.",
            example: "factor(x^2-4)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "expand",
            title: "expand(",
            category: .algebra,
            syntax: "expand(expr)",
            description: "Multiplies out products and powers: expand((x+1)*(x-2)) → x^2-x-2.",
            example: "expand((x+1)*(x-2))",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "comdenom",
            title: "comDenom(",
            category: .algebra,
            syntax: "comDenom(expr)",
            description: "Puts a sum of fractions over one common denominator: comDenom((x+1)/2+(x-1)/3) → 5/6*x+1/6. The input layer maps comDenom to the engine's normal command.",
            example: "comDenom((x+1)/2+(x-1)/3)",
            compatibility: .alias),

        CalculatorFunctionGuide(
            id: "propfrac",
            title: "propFrac(",
            category: .algebra,
            syntax: "propFrac(fraction, var)",
            description: "Rewrites an improper rational expression as a polynomial plus a remainder: propFrac((x^2+x+1)/(x+1)) → x+1/(x+1). The input layer maps propFrac to the engine's propfrac command.",
            example: "propFrac((x^2+x+1)/(x+1))",
            compatibility: .alias),

        CalculatorFunctionGuide(
            id: "nsolve",
            title: "nSolve(",
            category: .algebra,
            syntax: "nSolve(equation, var[, guess])",
            description: "Numeric root: nSolve(cos(x)=x,x) → [0.739085133215]. Add a guess to pick one root: nSolve(x^2-2=0,x,1) → 1.41421356237. The input layer maps nSolve to the engine's fsolve command.",
            example: "nSolve(cos(x)=x,x)",
            compatibility: .alias),

        CalculatorFunctionGuide(
            id: "with",
            title: "With ( | )",
            category: .algebra,
            syntax: "expr | var=value",
            description: "Substitutes a value: x^2+1 | x=3 → 10. Caution: on one line, the substitution can run before the command, so d(x^2,x) | x=3 substitutes inside the argument first. Store the result, then substitute: d(x^2,x)→fp, then fp | x=3 → 6.",
            example: "x^2+1 | x=3",
            compatibility: .verified),

        // MARK: Calculus

        CalculatorFunctionGuide(
            id: "derivative",
            title: "d( derivative",
            category: .calculus,
            syntax: "d(expr, var[, order])",
            description: "Derivative: d(x^3,x) → 3*x^2. Higher orders: d(x^3,x,2) → 6*x. The input layer maps d( to the engine's diff command.",
            example: "d(x^3,x)",
            compatibility: .alias),

        CalculatorFunctionGuide(
            id: "integral",
            title: "∫( integrate",
            category: .calculus,
            syntax: "∫(expr, var[, a, b])",
            description: "Without bounds, gives the antiderivative: ∫(x^2,x) → x^3/3. Definite: ∫(x^2,x,0,1) → 1/3, and ∫(sin(x),x,0,π) → 2.",
            example: "∫(x^2,x,0,1)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "limit",
            title: "limit(",
            category: .calculus,
            syntax: "limit(expr, var, point[, direction])",
            description: "limit(sin(x)/x,x,0) → 1. One-sided: limit(1/x,x,0,1) → +infinity.",
            example: "limit(sin(x)/x,x,0)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "sum-product",
            title: "Σ( and Π(",
            category: .calculus,
            syntax: "Σ(expr, k, a, b) · Π(expr, k, a, b)",
            description: "Σ(k^2,k,1,10) → 385. Π(k,k,1,4) → 24. The bounds can be symbolic: Σ(k,k,1,n) gives a closed form in n. The input layer maps Σ( and Π( to the engine's sum and product commands.",
            example: "Σ(k^2,k,1,10)",
            compatibility: .alias),

        CalculatorFunctionGuide(
            id: "taylor",
            title: "taylor(",
            category: .calculus,
            syntax: "taylor(expr, var, order)",
            description: "Taylor polynomial around 0: taylor(cos(x),x,4) → 1-1/2*x^2+1/24*x^4 plus a remainder term (order_size). The third argument is the order, as on the TI-89.",
            example: "taylor(cos(x),x,4)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "desolve",
            title: "deSolve(",
            category: .calculus,
            syntax: "deSolve(ode, indepVar, depVar)",
            description: "Solves an ordinary differential equation: deSolve(y'=y,x,y) → c_0*exp(x). The integration constants print as c_0, c_1, … Second example: deSolve(y''+y=0,x,y) → c_0*cos(x)+c_1*sin(x).",
            example: "deSolve(y'=y,x,y)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "nderiv",
            title: "nDeriv(",
            category: .calculus,
            syntax: "nDeriv(expr, var, point)",
            description: "Not the TI-89 behaviour. The engine's nDeriv treats the third argument as a step size and returns a difference quotient, not the slope at that point. To get a slope value, differentiate first, store, then substitute: d(x^2,x)→fp, then fp | x=3 → 6.",
            example: "nDeriv(x^2,x,3)",
            compatibility: .notYetVerified),

        CalculatorFunctionGuide(
            id: "impdif",
            title: "impDif(",
            category: .calculus,
            syntax: "impDif(equation, indepVar, depVar)",
            description: "Known gap: the entry comes back unevaluated. Solve the relation for y first, for example solve(x^2+y^2=4,y), then differentiate the branch expression by hand. There is no working implicit differentiation command here.",
            example: "impDif(x^2+y^2=4,x,y)",
            compatibility: .notYetVerified),

        // MARK: Trigonometry

        CalculatorFunctionGuide(
            id: "trig-basic",
            title: "sin( cos( tan(",
            category: .trigonometry,
            syntax: "sin(x) · cos(x) · tan(x)",
            description: "sin(π/6) → 1/2. Results follow the RAD/DEG setting in the MODE menu. cos( and tan( work the same way.",
            example: "sin(π/6)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "trig-inverse",
            title: "Inverse trig (asin, acos, atan)",
            category: .trigonometry,
            syntax: "asin(x) · acos(x) · atan(x)",
            description: "asin(1) → π/2; acos(0) → π/2; atan(1) → π/4. Type the plain names asin(, acos(, atan(. Caution: the TI-89's sin⁻¹( key spelling is not accepted here — it returns undef.",
            example: "asin(1)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "tcollect",
            title: "tCollect(",
            category: .trigonometry,
            syntax: "tCollect(expr)",
            description: "Collects products of trigonometric functions into sums: tCollect(sin(x)*cos(x)) → 1/2*sin(2*x). Also tCollect(cos(x)^2) → 1/2+1/2*cos(2*x).",
            example: "tCollect(sin(x)*cos(x))",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "texpand",
            title: "tExpand(",
            category: .trigonometry,
            syntax: "tExpand(expr)",
            description: "Known gap: the TI spelling does not expand angle sums. tExpand(sin(x+y)) returns sin(x+y), and expand( does not expand trigonometric functions either. The engine's own texpand( does expand: texpand(sin(x+y)) → sin(x)*cos(y)+cos(x)*sin(y).",
            example: "tExpand(sin(x+y))",
            compatibility: .notYetVerified),

        // MARK: Matrices

        CalculatorFunctionGuide(
            id: "matrix-literal",
            title: "Matrix entry and arithmetic",
            category: .matrices,
            syntax: "[[a,b][c,d]] · [a,b;c,d]",
            description: "Enter rows next to each other, [[1,2][3,4]], or with ; as [1,2;3,4]. Add, subtract and multiply with + - *; invert with ^(-1): [[1,2][3,4]]^(-1) → [[-2,1],[3/2,-1/2]]. transpose( swaps rows and columns, and identity(3) gives the identity matrix.",
            example: "[[1,2][3,4]]",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "det",
            title: "det(",
            category: .matrices,
            syntax: "det(matrix)",
            description: "Determinant: det([[1,2][3,4]]) → -2.",
            example: "det([[1,2][3,4]])",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "rref",
            title: "rref( and ref(",
            category: .matrices,
            syntax: "rref(matrix)",
            description: "Row-reduces to reduced row echelon form: rref([[1,2][3,4]]) → the 2×2 identity. ref( stops at plain echelon form: [[1,2],[0,1]].",
            example: "rref([[1,2][3,4]])",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "eigvl",
            title: "eigVl( and eigVc(",
            category: .matrices,
            syntax: "eigVl(matrix) · eigVc(matrix)",
            description: "eigVl( returns the eigenvalues as a diagonal matrix; eigVc( returns the eigenvectors. For [[1,2][3,4]] the eigenvalues print with sqrt(33), not as decimals, unless you force approx(.",
            example: "eigVl([[1,2][3,4]])",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "augment",
            title: "augment( and dim(",
            category: .matrices,
            syntax: "augment(matrixA, matrixB)",
            description: "Joins matrices side by side: augment([[1,2]],[[3,4]]) → [[1,2,3,4]]. dim( gives the size of a matrix or a list: dim([[1,2][3,4]]) → [2,2].",
            example: "augment([[1,2]],[[3,4]])",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "simult",
            title: "simult(",
            category: .matrices,
            syntax: "simult(matrix, constants)",
            description: "Known gap: the engine reports a bad argument value. Solve linear systems with linsolve instead: linsolve([x+y=3,x-y=1],[x,y]) → [2,1]. solve({x+y=3,x-y=1},{x,y}) also works.",
            example: "simult([[2,0][0,2]],[3,4])",
            compatibility: .notYetVerified),

        // MARK: Lists

        CalculatorFunctionGuide(
            id: "list-literal",
            title: "List entry and arithmetic",
            category: .lists,
            syntax: "{a,b,c}",
            description: "Lists use braces: {1,2,3}. Arithmetic applies element by element: {1,2,3}*2 doubles each element to 2, 4, 6. sort({3,1,2}) sorts a list in ascending order: 1, 2, 3.",
            example: "{1,2,3}",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "seq",
            title: "seq(",
            category: .lists,
            syntax: "seq(expr, k, start, end[, step])",
            description: "Builds a list of values: seq(k^2,k,1,4) gives the squares 1, 4, 9, 16. Use it together with sum( or cumSum(.",
            example: "seq(k^2,k,1,4)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "list-sum",
            title: "sum( and cumSum(",
            category: .lists,
            syntax: "sum(list) · cumSum(list)",
            description: "sum({1,2,3}) → 6. cumSum({1,2,3}) gives the running totals 1, 3, 6.",
            example: "sum({1,2,3})",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "list-stats",
            title: "List statistics",
            category: .lists,
            syntax: "mean( · stdDev( · min( · max(",
            description: "mean({1,2,3}) → 2. stdDev({1,2,3}) → 1. min( and max( pick the extremes: max({3,1,2}) → 3.",
            example: "mean({1,2,3})",
            compatibility: .verified),

        // MARK: Numbers

        CalculatorFunctionGuide(
            id: "gcd-lcm",
            title: "gcd( and lcm(",
            category: .numbers,
            syntax: "gcd(a, b) · lcm(a, b)",
            description: "gcd(12,18) → 6; lcm(4,6) → 12. Both also accept polynomial arguments: gcd(x^2-1,x^2+2*x+1) → x+1.",
            example: "gcd(12,18)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "mod",
            title: "mod(",
            category: .numbers,
            syntax: "mod(a, b)",
            description: "Remainder after division: mod(17,5) → 2. Write it as a function call; the engine does not accept the infix form 17 mod 5.",
            example: "mod(17,5)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "isprime",
            title: "isPrime( and ifactor(",
            category: .numbers,
            syntax: "isPrime(n) · ifactor(n)",
            description: "isPrime(17) → true. ifactor( gives an integer's prime factors: ifactor(12) → 2^2*3.",
            example: "isPrime(17)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "rounding",
            title: "round( floor( ceiling(",
            category: .numbers,
            syntax: "round(x[, digits]) · floor(x) · ceiling(x)",
            description: "round(2.567,2) → 2.57. floor(2.7) → 2 and ceiling(2.1) → 3. int(, iPart( and fPart( also work.",
            example: "round(2.567,2)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "ncr-npr",
            title: "nCr( and nPr(",
            category: .numbers,
            syntax: "nCr(n, k) · nPr(n, k)",
            description: "Combinations and permutations: nCr(5,2) → 10; nPr(5,2) → 20.",
            example: "nCr(5,2)",
            compatibility: .verified),

        // MARK: Complex

        CalculatorFunctionGuide(
            id: "complex-arith",
            title: "Complex numbers (i)",
            category: .complex,
            syntax: "a+b*i · √(-x) · cSolve(",
            description: "The imaginary unit prints as i: √(-4) → 2*i. Complex solutions come from cSolve( and cZeros(.",
            example: "√(-4)",
            compatibility: .verified),

        CalculatorFunctionGuide(
            id: "complex-parts",
            title: "real( imag( conj( abs(",
            category: .complex,
            syntax: "real(z) · imag(z) · conj(z) · abs(z)",
            description: "Known gap: on a complex number like 3+4*i these come back unevaluated, even in APPROX mode. Read the parts from the printed result instead. Complex results from cSolve( and cZeros( do work.",
            example: "real(3+4*i)",
            compatibility: .notYetVerified),
    ]

    /// Searches the catalogue. Matches title, syntax, and description,
    /// case-insensitively. An empty or blank query returns every entry in
    /// the category. A nil category searches all categories.
    static func search(query: String,
                      category: CalculatorFunctionCategory?) -> [CalculatorFunctionGuide] {
        let pool: [CalculatorFunctionGuide]
        if let category {
            pool = entries.filter { $0.category == category }
        } else {
            pool = entries
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return pool }
        return pool.filter { entry in
            entry.title.lowercased().contains(needle)
            || entry.syntax.lowercased().contains(needle)
            || entry.description.lowercased().contains(needle)
        }
    }
}
