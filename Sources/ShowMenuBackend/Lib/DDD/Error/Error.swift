//
//  Error.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 9/13/25.
//

enum MappingError: Error {
    case invalidData
    case missingRequiredField(field: String)
}

// MARK: - Domain Errors

protocol DomainError: Error {

}

protocol ValidationError: DomainError {
    
}

// MARK: - Integration Errors

protocol IntegrationError: Error {

}
