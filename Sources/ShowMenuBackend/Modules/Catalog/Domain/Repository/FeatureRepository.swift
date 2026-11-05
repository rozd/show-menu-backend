import Foundation

protocol FeatureRepository: Repository where Entity == Feature, Model == FeatureModel, DTO == FeatureDTO {
}
