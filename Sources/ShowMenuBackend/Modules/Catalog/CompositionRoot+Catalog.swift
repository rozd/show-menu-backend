import Vapor

extension Application.CompositionRoot {

    // MARK: Catalog — Mappers

    var featureMapper: FeatureMapper {
        resolver.resolve(\.featureMapper) {
            FeatureMapper()
        }
    }

    // MARK: Catalog — Data Sources

    var featureDataSourceFactory: DataSourceFactory<FeatureModel> {
        resolver.resolve(\.featureDataSourceFactory) {
            { [logger = app.logger] prefix, transaction in
                FirestoreFeatureDataSource(
                    transaction: transaction as! FirestoreTransaction,
                    prefix: firestorePrefix(prefix),
                    logger: logger
                )
            }
        }
    }

    // MARK: Catalog — Repositories

    var featureRepositoryFactory: RepositoryFactory<any FeatureRepository> {
        resolver.resolve(\.featureRepositoryFactory) {
            { ctx in
                FirestoreFeatureRepository(
                    mapper: featureMapper,
                    dataSourceFactory: featureDataSourceFactory,
                    context: ctx
                )
            }
        }
    }

    // MARK: Catalog — Use Cases

    var createFeatureUseCaseFactory: UseCaseFactory<CreateFeatureUseCase> {
        resolver.resolve(\.createFeatureUseCaseFactory) {
            { [logger = app.logger] ctx in
                CreateFeatureUseCase(
                    context: ctx,
                    repositoryFactory: featureRepositoryFactory,
                    mapper: featureMapper,
                    logger: logger
                )
            }
        }
    }

    var updateFeatureUseCaseFactory: UseCaseFactory<UpdateFeatureUseCase> {
        resolver.resolve(\.updateFeatureUseCaseFactory) {
            { [logger = app.logger] ctx in
                UpdateFeatureUseCase(
                    context: ctx,
                    repositoryFactory: featureRepositoryFactory,
                    mapper: featureMapper,
                    logger: logger
                )
            }
        }
    }

    // MARK: Catalog — Command Handlers

    var createFeatureCommandHandler: CreateFeatureCommandHandler {
        resolver.resolve(\.createFeatureCommandHandler) {
            CreateFeatureCommandHandler(
                unitOfWork: unitOfWork,
                useCaseFactory: createFeatureUseCaseFactory,
                logger: app.logger
            )
        }
    }

    var updateFeatureCommandHandler: UpdateFeatureCommandHandler {
        resolver.resolve(\.updateFeatureCommandHandler) {
            UpdateFeatureCommandHandler(
                unitOfWork: unitOfWork,
                useCaseFactory: updateFeatureUseCaseFactory,
                logger: app.logger
            )
        }
    }
}
