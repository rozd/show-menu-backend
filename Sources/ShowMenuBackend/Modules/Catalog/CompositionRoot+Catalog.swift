import Vapor

extension Application.CompositionRoot {

    // MARK: Catalog — Mappers

    var featureMapper: FeatureMapper {
        resolver.resolve(\.featureMapper) {
            FeatureMapper()
        }
    }

    var planMapper: PlanMapper {
        resolver.resolve(\.planMapper) {
            PlanMapper()
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

    var planDataSourceFactory: DataSourceFactory<PlanModel> {
        resolver.resolve(\.planDataSourceFactory) {
            { [logger = app.logger] prefix, transaction in
                FirestorePlanDataSource(
                    transaction: transaction as! FirestoreTransaction,
                    prefix: firestorePrefix(prefix),
                    logger: logger
                )
            }
        }
    }

    var planSKUDataSourceFactory: DataSourceFactory<PlanSKUModel> {
        resolver.resolve(\.planSKUDataSourceFactory) {
            { [logger = app.logger] prefix, transaction in
                FirestorePlanSKUDataSource(
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

    var planRepositoryFactory: RepositoryFactory<any PlanRepository> {
        resolver.resolve(\.planRepositoryFactory) {
            { ctx in
                FirestorePlanRepository(
                    mapper: planMapper,
                    dataSourceFactory: planDataSourceFactory,
                    skuDataSourceFactory: planSKUDataSourceFactory,
                    context: ctx,
                    lookupTransaction: { [firestore] in FirestoreTransaction.direct(firestore: firestore) }
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

    var createPlanUseCaseFactory: UseCaseFactory<CreatePlanUseCase> {
        resolver.resolve(\.createPlanUseCaseFactory) {
            { [logger = app.logger] ctx in
                CreatePlanUseCase(
                    context: ctx,
                    repositoryFactory: planRepositoryFactory,
                    mapper: planMapper,
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

    var createPlanCommandHandler: CreatePlanCommandHandler {
        resolver.resolve(\.createPlanCommandHandler) {
            CreatePlanCommandHandler(
                unitOfWork: unitOfWork,
                useCaseFactory: createPlanUseCaseFactory,
                logger: app.logger
            )
        }
    }

    // MARK: Catalog — Query Handlers

    var getPlanQueryHandler: GetPlanQueryHandler {
        resolver.resolve(\.getPlanQueryHandler) {
            GetPlanQueryHandler(
                dataSourceFactory: planDataSourceFactory,
                transaction: .direct(firestore: firestore),
                mapper: planMapper,
                logger: app.logger
            )
        }
    }

    var listPlansQueryHandler: ListPlansQueryHandler {
        resolver.resolve(\.listPlansQueryHandler) {
            ListPlansQueryHandler(
                dataSourceFactory: planDataSourceFactory,
                transaction: .direct(firestore: firestore),
                mapper: planMapper,
                logger: app.logger
            )
        }
    }
}
