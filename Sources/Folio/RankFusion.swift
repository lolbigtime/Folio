//
//  RankFusion.swift
//  Folio
//
//  Created by Tai Wong on 9/20/25.
//

public enum RankFusion {
    private static func normBM25(_ all: [Double], _ x: Double) -> Double {
        guard let min = all.min(), let max = all.max(), max > min else { return 1.0 }
        return (max - x) / (max - min)
    }
    private static func normCos(_ x: Double) -> Double { max(0, min(1, (x + 1.0) / 2.0)) }

    public static func fuse(bm25 all: [Double], bm25 x: Double, cosine y: Double?, wBM25: Double = 0.5) -> Double {
        let nb = normBM25(all, x)
        guard let y else { return nb }
        return wBM25 * nb + (1 - wBM25) * normCos(y)
    }
}
