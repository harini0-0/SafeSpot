//  HouseLoader.swift
//  Loads the bundled real house data + mesh and derives the house graph and the
//  C3 mesh segmentation, all via SafeSpotCore (the tested, deterministic logic).
//  The bundled files are verbatim copies of data/zyzG7fqtBDv.json and the 50k mesh;
//  the originals in data/ are never modified.

import Foundation
import SafeSpotCore

struct LoadedHouse {
    let model: MatterportModel
    let graph: HouseGraph
    let mesh: LoadedMesh
    let segmentation: MeshSegmentation
}

enum HouseLoadError: LocalizedError {
    case missingResource(String)
    var errorDescription: String? {
        switch self {
        case .missingResource(let n): return "Bundled resource not found: \(n)"
        }
    }
}

enum HouseLoader {
    static func loadFromBundle() throws -> LoadedHouse {
        guard let jsonURL = resourceURL("zyzG7fqtBDv", "json") else {
            throw HouseLoadError.missingResource("zyzG7fqtBDv.json")
        }
        guard let objURL = resourceURL("house_50k", "obj") else {
            throw HouseLoadError.missingResource("house_50k.obj")
        }
        let model = try MatterportModel.load(contentsOf: jsonURL)
        let graph = HouseGraph(model: model)
        let mesh = try OBJLoader.load(contentsOf: objURL)
        let segmentation = MeshSegmentation(mesh: mesh, graph: graph)
        return LoadedHouse(model: model, graph: graph, mesh: mesh, segmentation: segmentation)
    }

    /// Synced-folder resources may land at the bundle root or under "Resources".
    private static func resourceURL(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }
}
