import ShowMenuContracts

/// Every contract operation that has no implementation yet. Each answers `501 not_implemented`
/// (see ``NotImplementedError``) and is not in ``ContractAccessMiddleware/table``, so it is
/// unreachable through the access gate anyway (401) until it is implemented.
///
/// To implement an operation: delete its method here, add it to a
/// `ContractAPI+<Module>.swift` that forwards to a plain controller, and add it to the
/// access table. Grouped by contract tag.
extension ContractAPI {

    // MARK: - Owners

    func getCurrentOwner(_ input: Operations.GetCurrentOwner.Input) async throws -> Operations.GetCurrentOwner.Output {
        throw NotImplementedError(operationID: Operations.GetCurrentOwner.id)
    }

    func updateCurrentOwner(_ input: Operations.UpdateCurrentOwner.Input) async throws -> Operations.UpdateCurrentOwner.Output {
        throw NotImplementedError(operationID: Operations.UpdateCurrentOwner.id)
    }

    func listOwners(_ input: Operations.ListOwners.Input) async throws -> Operations.ListOwners.Output {
        throw NotImplementedError(operationID: Operations.ListOwners.id)
    }

    func getOwner(_ input: Operations.GetOwner.Input) async throws -> Operations.GetOwner.Output {
        throw NotImplementedError(operationID: Operations.GetOwner.id)
    }

    func removeOwner(_ input: Operations.RemoveOwner.Input) async throws -> Operations.RemoveOwner.Output {
        throw NotImplementedError(operationID: Operations.RemoveOwner.id)
    }

    // MARK: - Invitations

    func listInvitations(_ input: Operations.ListInvitations.Input) async throws -> Operations.ListInvitations.Output {
        throw NotImplementedError(operationID: Operations.ListInvitations.id)
    }

    func createInvitation(_ input: Operations.CreateInvitation.Input) async throws -> Operations.CreateInvitation.Output {
        throw NotImplementedError(operationID: Operations.CreateInvitation.id)
    }

    func getInvitation(_ input: Operations.GetInvitation.Input) async throws -> Operations.GetInvitation.Output {
        throw NotImplementedError(operationID: Operations.GetInvitation.id)
    }

    func revokeInvitation(_ input: Operations.RevokeInvitation.Input) async throws -> Operations.RevokeInvitation.Output {
        throw NotImplementedError(operationID: Operations.RevokeInvitation.id)
    }

    func resendInvitation(_ input: Operations.ResendInvitation.Input) async throws -> Operations.ResendInvitation.Output {
        throw NotImplementedError(operationID: Operations.ResendInvitation.id)
    }

    func acceptInvitation(_ input: Operations.AcceptInvitation.Input) async throws -> Operations.AcceptInvitation.Output {
        throw NotImplementedError(operationID: Operations.AcceptInvitation.id)
    }

    // MARK: - Businesses

    func createBusiness(_ input: Operations.CreateBusiness.Input) async throws -> Operations.CreateBusiness.Output {
        throw NotImplementedError(operationID: Operations.CreateBusiness.id)
    }

    func getBusiness(_ input: Operations.GetBusiness.Input) async throws -> Operations.GetBusiness.Output {
        throw NotImplementedError(operationID: Operations.GetBusiness.id)
    }

    func updateBusiness(_ input: Operations.UpdateBusiness.Input) async throws -> Operations.UpdateBusiness.Output {
        throw NotImplementedError(operationID: Operations.UpdateBusiness.id)
    }

    func deleteBusiness(_ input: Operations.DeleteBusiness.Input) async throws -> Operations.DeleteBusiness.Output {
        throw NotImplementedError(operationID: Operations.DeleteBusiness.id)
    }

    func getLegalDetails(_ input: Operations.GetLegalDetails.Input) async throws -> Operations.GetLegalDetails.Output {
        throw NotImplementedError(operationID: Operations.GetLegalDetails.id)
    }

    func setLegalDetails(_ input: Operations.SetLegalDetails.Input) async throws -> Operations.SetLegalDetails.Output {
        throw NotImplementedError(operationID: Operations.SetLegalDetails.id)
    }

    func createBrandingUpload(_ input: Operations.CreateBrandingUpload.Input) async throws -> Operations.CreateBrandingUpload.Output {
        throw NotImplementedError(operationID: Operations.CreateBrandingUpload.id)
    }

    func publishBusiness(_ input: Operations.PublishBusiness.Input) async throws -> Operations.PublishBusiness.Output {
        throw NotImplementedError(operationID: Operations.PublishBusiness.id)
    }

    func startBusiness(_ input: Operations.StartBusiness.Input) async throws -> Operations.StartBusiness.Output {
        throw NotImplementedError(operationID: Operations.StartBusiness.id)
    }

    // MARK: - Subscription

    func listSubscriptionPlans(_ input: Operations.ListSubscriptionPlans.Input) async throws -> Operations.ListSubscriptionPlans.Output {
        throw NotImplementedError(operationID: Operations.ListSubscriptionPlans.id)
    }

    func getSubscription(_ input: Operations.GetSubscription.Input) async throws -> Operations.GetSubscription.Output {
        throw NotImplementedError(operationID: Operations.GetSubscription.id)
    }

    func createSubscriptionCheckout(_ input: Operations.CreateSubscriptionCheckout.Input) async throws -> Operations.CreateSubscriptionCheckout.Output {
        throw NotImplementedError(operationID: Operations.CreateSubscriptionCheckout.id)
    }

    func setScheduledPlan(_ input: Operations.SetScheduledPlan.Input) async throws -> Operations.SetScheduledPlan.Output {
        throw NotImplementedError(operationID: Operations.SetScheduledPlan.id)
    }

    func withdrawScheduledPlan(_ input: Operations.WithdrawScheduledPlan.Input) async throws -> Operations.WithdrawScheduledPlan.Output {
        throw NotImplementedError(operationID: Operations.WithdrawScheduledPlan.id)
    }

    func cancelSubscription(_ input: Operations.CancelSubscription.Input) async throws -> Operations.CancelSubscription.Output {
        throw NotImplementedError(operationID: Operations.CancelSubscription.id)
    }

    func resumeSubscription(_ input: Operations.ResumeSubscription.Input) async throws -> Operations.ResumeSubscription.Output {
        throw NotImplementedError(operationID: Operations.ResumeSubscription.id)
    }

    func getFreePlanPick(_ input: Operations.GetFreePlanPick.Input) async throws -> Operations.GetFreePlanPick.Output {
        throw NotImplementedError(operationID: Operations.GetFreePlanPick.id)
    }

    func updateFreePlanPick(_ input: Operations.UpdateFreePlanPick.Input) async throws -> Operations.UpdateFreePlanPick.Output {
        throw NotImplementedError(operationID: Operations.UpdateFreePlanPick.id)
    }

    func createLocationAddOnCheckout(_ input: Operations.CreateLocationAddOnCheckout.Input) async throws -> Operations.CreateLocationAddOnCheckout.Output {
        throw NotImplementedError(operationID: Operations.CreateLocationAddOnCheckout.id)
    }

    // MARK: - Billing

    func listPayments(_ input: Operations.ListPayments.Input) async throws -> Operations.ListPayments.Output {
        throw NotImplementedError(operationID: Operations.ListPayments.id)
    }

    func listBillingDocuments(_ input: Operations.ListBillingDocuments.Input) async throws -> Operations.ListBillingDocuments.Output {
        throw NotImplementedError(operationID: Operations.ListBillingDocuments.id)
    }

    func getBillingDocumentDownload(_ input: Operations.GetBillingDocumentDownload.Input) async throws -> Operations.GetBillingDocumentDownload.Output {
        throw NotImplementedError(operationID: Operations.GetBillingDocumentDownload.id)
    }

    func listPhotoCreditPackSizes(_ input: Operations.ListPhotoCreditPackSizes.Input) async throws -> Operations.ListPhotoCreditPackSizes.Output {
        throw NotImplementedError(operationID: Operations.ListPhotoCreditPackSizes.id)
    }

    func createPhotoCreditPackCheckout(_ input: Operations.CreatePhotoCreditPackCheckout.Input) async throws -> Operations.CreatePhotoCreditPackCheckout.Output {
        throw NotImplementedError(operationID: Operations.CreatePhotoCreditPackCheckout.id)
    }

    func listPhotoCreditPacks(_ input: Operations.ListPhotoCreditPacks.Input) async throws -> Operations.ListPhotoCreditPacks.Output {
        throw NotImplementedError(operationID: Operations.ListPhotoCreditPacks.id)
    }

    func getPhotoCreditBalance(_ input: Operations.GetPhotoCreditBalance.Input) async throws -> Operations.GetPhotoCreditBalance.Output {
        throw NotImplementedError(operationID: Operations.GetPhotoCreditBalance.id)
    }

    func getAiUsage(_ input: Operations.GetAiUsage.Input) async throws -> Operations.GetAiUsage.Output {
        throw NotImplementedError(operationID: Operations.GetAiUsage.id)
    }

    // MARK: - Segment Templates

    func listSegmentTemplates(_ input: Operations.ListSegmentTemplates.Input) async throws -> Operations.ListSegmentTemplates.Output {
        throw NotImplementedError(operationID: Operations.ListSegmentTemplates.id)
    }

    // MARK: - Locations

    func listLocations(_ input: Operations.ListLocations.Input) async throws -> Operations.ListLocations.Output {
        throw NotImplementedError(operationID: Operations.ListLocations.id)
    }

    func createLocation(_ input: Operations.CreateLocation.Input) async throws -> Operations.CreateLocation.Output {
        throw NotImplementedError(operationID: Operations.CreateLocation.id)
    }

    func getLocation(_ input: Operations.GetLocation.Input) async throws -> Operations.GetLocation.Output {
        throw NotImplementedError(operationID: Operations.GetLocation.id)
    }

    func updateLocation(_ input: Operations.UpdateLocation.Input) async throws -> Operations.UpdateLocation.Output {
        throw NotImplementedError(operationID: Operations.UpdateLocation.id)
    }

    func deleteLocation(_ input: Operations.DeleteLocation.Input) async throws -> Operations.DeleteLocation.Output {
        throw NotImplementedError(operationID: Operations.DeleteLocation.id)
    }

    // MARK: - QR Codes

    func listQrCodes(_ input: Operations.ListQrCodes.Input) async throws -> Operations.ListQrCodes.Output {
        throw NotImplementedError(operationID: Operations.ListQrCodes.id)
    }

    func createQrCode(_ input: Operations.CreateQrCode.Input) async throws -> Operations.CreateQrCode.Output {
        throw NotImplementedError(operationID: Operations.CreateQrCode.id)
    }

    func getQrCode(_ input: Operations.GetQrCode.Input) async throws -> Operations.GetQrCode.Output {
        throw NotImplementedError(operationID: Operations.GetQrCode.id)
    }

    func updateQrCode(_ input: Operations.UpdateQrCode.Input) async throws -> Operations.UpdateQrCode.Output {
        throw NotImplementedError(operationID: Operations.UpdateQrCode.id)
    }

    func deleteQrCode(_ input: Operations.DeleteQrCode.Input) async throws -> Operations.DeleteQrCode.Output {
        throw NotImplementedError(operationID: Operations.DeleteQrCode.id)
    }

    func downloadQrCode(_ input: Operations.DownloadQrCode.Input) async throws -> Operations.DownloadQrCode.Output {
        throw NotImplementedError(operationID: Operations.DownloadQrCode.id)
    }

    // MARK: - Menu

    func getMenu(_ input: Operations.GetMenu.Input) async throws -> Operations.GetMenu.Output {
        throw NotImplementedError(operationID: Operations.GetMenu.id)
    }

    func updateMenu(_ input: Operations.UpdateMenu.Input) async throws -> Operations.UpdateMenu.Output {
        throw NotImplementedError(operationID: Operations.UpdateMenu.id)
    }

    func listCategories(_ input: Operations.ListCategories.Input) async throws -> Operations.ListCategories.Output {
        throw NotImplementedError(operationID: Operations.ListCategories.id)
    }

    func createCategory(_ input: Operations.CreateCategory.Input) async throws -> Operations.CreateCategory.Output {
        throw NotImplementedError(operationID: Operations.CreateCategory.id)
    }

    func getCategory(_ input: Operations.GetCategory.Input) async throws -> Operations.GetCategory.Output {
        throw NotImplementedError(operationID: Operations.GetCategory.id)
    }

    func updateCategory(_ input: Operations.UpdateCategory.Input) async throws -> Operations.UpdateCategory.Output {
        throw NotImplementedError(operationID: Operations.UpdateCategory.id)
    }

    func deleteCategory(_ input: Operations.DeleteCategory.Input) async throws -> Operations.DeleteCategory.Output {
        throw NotImplementedError(operationID: Operations.DeleteCategory.id)
    }

    func listItems(_ input: Operations.ListItems.Input) async throws -> Operations.ListItems.Output {
        throw NotImplementedError(operationID: Operations.ListItems.id)
    }

    func createItem(_ input: Operations.CreateItem.Input) async throws -> Operations.CreateItem.Output {
        throw NotImplementedError(operationID: Operations.CreateItem.id)
    }

    func getItem(_ input: Operations.GetItem.Input) async throws -> Operations.GetItem.Output {
        throw NotImplementedError(operationID: Operations.GetItem.id)
    }

    func updateItem(_ input: Operations.UpdateItem.Input) async throws -> Operations.UpdateItem.Output {
        throw NotImplementedError(operationID: Operations.UpdateItem.id)
    }

    func deleteItem(_ input: Operations.DeleteItem.Input) async throws -> Operations.DeleteItem.Output {
        throw NotImplementedError(operationID: Operations.DeleteItem.id)
    }

    func listTags(_ input: Operations.ListTags.Input) async throws -> Operations.ListTags.Output {
        throw NotImplementedError(operationID: Operations.ListTags.id)
    }

    func createTag(_ input: Operations.CreateTag.Input) async throws -> Operations.CreateTag.Output {
        throw NotImplementedError(operationID: Operations.CreateTag.id)
    }

    func getTag(_ input: Operations.GetTag.Input) async throws -> Operations.GetTag.Output {
        throw NotImplementedError(operationID: Operations.GetTag.id)
    }

    func updateTag(_ input: Operations.UpdateTag.Input) async throws -> Operations.UpdateTag.Output {
        throw NotImplementedError(operationID: Operations.UpdateTag.id)
    }

    func deleteTag(_ input: Operations.DeleteTag.Input) async throws -> Operations.DeleteTag.Output {
        throw NotImplementedError(operationID: Operations.DeleteTag.id)
    }

    func createItemPhotoUpload(_ input: Operations.CreateItemPhotoUpload.Input) async throws -> Operations.CreateItemPhotoUpload.Output {
        throw NotImplementedError(operationID: Operations.CreateItemPhotoUpload.id)
    }

    func listItemPhotos(_ input: Operations.ListItemPhotos.Input) async throws -> Operations.ListItemPhotos.Output {
        throw NotImplementedError(operationID: Operations.ListItemPhotos.id)
    }

    func createItemPhoto(_ input: Operations.CreateItemPhoto.Input) async throws -> Operations.CreateItemPhoto.Output {
        throw NotImplementedError(operationID: Operations.CreateItemPhoto.id)
    }

    func getItemPhoto(_ input: Operations.GetItemPhoto.Input) async throws -> Operations.GetItemPhoto.Output {
        throw NotImplementedError(operationID: Operations.GetItemPhoto.id)
    }

    func updateItemPhoto(_ input: Operations.UpdateItemPhoto.Input) async throws -> Operations.UpdateItemPhoto.Output {
        throw NotImplementedError(operationID: Operations.UpdateItemPhoto.id)
    }

    func deleteItemPhoto(_ input: Operations.DeleteItemPhoto.Input) async throws -> Operations.DeleteItemPhoto.Output {
        throw NotImplementedError(operationID: Operations.DeleteItemPhoto.id)
    }

    func createEnhanceJob(_ input: Operations.CreateEnhanceJob.Input) async throws -> Operations.CreateEnhanceJob.Output {
        throw NotImplementedError(operationID: Operations.CreateEnhanceJob.id)
    }

    func getEnhanceJob(_ input: Operations.GetEnhanceJob.Input) async throws -> Operations.GetEnhanceJob.Output {
        throw NotImplementedError(operationID: Operations.GetEnhanceJob.id)
    }

    func acceptEnhanceJob(_ input: Operations.AcceptEnhanceJob.Input) async throws -> Operations.AcceptEnhanceJob.Output {
        throw NotImplementedError(operationID: Operations.AcceptEnhanceJob.id)
    }

    func declineEnhanceJob(_ input: Operations.DeclineEnhanceJob.Input) async throws -> Operations.DeclineEnhanceJob.Output {
        throw NotImplementedError(operationID: Operations.DeclineEnhanceJob.id)
    }

    func listUnavailableItems(_ input: Operations.ListUnavailableItems.Input) async throws -> Operations.ListUnavailableItems.Output {
        throw NotImplementedError(operationID: Operations.ListUnavailableItems.id)
    }

    func markItemUnavailable(_ input: Operations.MarkItemUnavailable.Input) async throws -> Operations.MarkItemUnavailable.Output {
        throw NotImplementedError(operationID: Operations.MarkItemUnavailable.id)
    }

    func markItemAvailable(_ input: Operations.MarkItemAvailable.Input) async throws -> Operations.MarkItemAvailable.Output {
        throw NotImplementedError(operationID: Operations.MarkItemAvailable.id)
    }

    // MARK: - Bulk Edit

    func listBulkEditBatches(_ input: Operations.ListBulkEditBatches.Input) async throws -> Operations.ListBulkEditBatches.Output {
        throw NotImplementedError(operationID: Operations.ListBulkEditBatches.id)
    }

    func planBulkEditBatch(_ input: Operations.PlanBulkEditBatch.Input) async throws -> Operations.PlanBulkEditBatch.Output {
        throw NotImplementedError(operationID: Operations.PlanBulkEditBatch.id)
    }

    func getBulkEditBatch(_ input: Operations.GetBulkEditBatch.Input) async throws -> Operations.GetBulkEditBatch.Output {
        throw NotImplementedError(operationID: Operations.GetBulkEditBatch.id)
    }

    func listBulkEditRows(_ input: Operations.ListBulkEditRows.Input) async throws -> Operations.ListBulkEditRows.Output {
        throw NotImplementedError(operationID: Operations.ListBulkEditRows.id)
    }

    func getBulkEditRow(_ input: Operations.GetBulkEditRow.Input) async throws -> Operations.GetBulkEditRow.Output {
        throw NotImplementedError(operationID: Operations.GetBulkEditRow.id)
    }

    func updateBulkEditRow(_ input: Operations.UpdateBulkEditRow.Input) async throws -> Operations.UpdateBulkEditRow.Output {
        throw NotImplementedError(operationID: Operations.UpdateBulkEditRow.id)
    }

    func setBulkEditTickedRows(_ input: Operations.SetBulkEditTickedRows.Input) async throws -> Operations.SetBulkEditTickedRows.Output {
        throw NotImplementedError(operationID: Operations.SetBulkEditTickedRows.id)
    }

    func replanBulkEditBatch(_ input: Operations.ReplanBulkEditBatch.Input) async throws -> Operations.ReplanBulkEditBatch.Output {
        throw NotImplementedError(operationID: Operations.ReplanBulkEditBatch.id)
    }

    func applyBulkEditBatch(_ input: Operations.ApplyBulkEditBatch.Input) async throws -> Operations.ApplyBulkEditBatch.Output {
        throw NotImplementedError(operationID: Operations.ApplyBulkEditBatch.id)
    }

    func undoBulkEditBatch(_ input: Operations.UndoBulkEditBatch.Input) async throws -> Operations.UndoBulkEditBatch.Output {
        throw NotImplementedError(operationID: Operations.UndoBulkEditBatch.id)
    }

    func discardBulkEditBatch(_ input: Operations.DiscardBulkEditBatch.Input) async throws -> Operations.DiscardBulkEditBatch.Output {
        throw NotImplementedError(operationID: Operations.DiscardBulkEditBatch.id)
    }

    // MARK: - Assistant

    func listPresets(_ input: Operations.ListPresets.Input) async throws -> Operations.ListPresets.Output {
        throw NotImplementedError(operationID: Operations.ListPresets.id)
    }

    func createPreset(_ input: Operations.CreatePreset.Input) async throws -> Operations.CreatePreset.Output {
        throw NotImplementedError(operationID: Operations.CreatePreset.id)
    }

    func getPreset(_ input: Operations.GetPreset.Input) async throws -> Operations.GetPreset.Output {
        throw NotImplementedError(operationID: Operations.GetPreset.id)
    }

    func updatePreset(_ input: Operations.UpdatePreset.Input) async throws -> Operations.UpdatePreset.Output {
        throw NotImplementedError(operationID: Operations.UpdatePreset.id)
    }

    func deletePreset(_ input: Operations.DeletePreset.Input) async throws -> Operations.DeletePreset.Output {
        throw NotImplementedError(operationID: Operations.DeletePreset.id)
    }

    func askAssistant(_ input: Operations.AskAssistant.Input) async throws -> Operations.AskAssistant.Output {
        throw NotImplementedError(operationID: Operations.AskAssistant.id)
    }

    // MARK: - Showcase

    func countScan(_ input: Operations.CountScan.Input) async throws -> Operations.CountScan.Output {
        throw NotImplementedError(operationID: Operations.CountScan.id)
    }

    // MARK: - Payments

    func handleLiqPayCallback(_ input: Operations.HandleLiqPayCallback.Input) async throws -> Operations.HandleLiqPayCallback.Output {
        throw NotImplementedError(operationID: Operations.HandleLiqPayCallback.id)
    }

    // MARK: - Internal

    func checkExpiredSubscriptions(_ input: Operations.CheckExpiredSubscriptions.Input) async throws -> Operations.CheckExpiredSubscriptions.Output {
        throw NotImplementedError(operationID: Operations.CheckExpiredSubscriptions.id)
    }
}
