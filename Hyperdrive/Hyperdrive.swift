//
//  Hyperdrive.swift
//  Hyperdrive
//
//  Created by Kyle Fuller on 08/04/2015.
//  Copyright (c) 2015 Apiary. All rights reserved.
//

import Foundation
import Representor
import URITemplate


/// Map a dictionaries values
func map<K,V>(source:[K:V], transform:(V -> V)) -> [K:V] {
  var result = [K:V]()

  for (key, value) in source {
    result[key] = transform(value)
  }

  return result
}

/// Returns an absolute URI for a URI given a base URL
func absoluteURI(baseURL:NSURL?)(uri:String) -> String {
  return NSURL(string: uri, relativeToURL: baseURL)?.absoluteString ?? uri
}

/// Traverses a representor and ensures that all URIs are absolute given a base URL
func absoluteRepresentor(baseURL:NSURL?)(original:Representor<HTTPTransition>) -> Representor<HTTPTransition> {
  let transitions = map(original.transitions) { transition in
    return HTTPTransition(uri: absoluteURI(baseURL)(uri: transition.uri)) { builder in
      builder.method = transition.method
      builder.suggestedContentTypes = transition.suggestedContentTypes

      for (name, attribute) in transition.attributes {
        builder.addAttribute(name, value: attribute.value, defaultValue: attribute.defaultValue)
      }

      for (name, parameter) in transition.parameters {
        builder.addParameter(name, value: parameter.value, defaultValue: parameter.defaultValue)
      }
    }
  }

  let representors = map(original.representors) { representors in
    return representors.map(absoluteRepresentor(baseURL))
  }

  return Representor(transitions: transitions, representors: representors, attributes: original.attributes, metadata: original.metadata)
}


/// An enumeration representing a Hyperdrive result, containing either a success Representor or a Failure error
public enum Result {
  /// The operation succeeded and returned a Representor
  case Success(Representor<HTTPTransition>)

  /// The operation failed and returned an error
  case Failure(NSError)
}


public enum RequestResult {
  case Success(NSMutableURLRequest)
  case Failure(NSError)

  func flatMap(transform:(NSMutableURLRequest -> RequestResult)) -> RequestResult {
    switch self {
    case .Success(let request):
      return transform(request)
    case .Failure(let error):
        return self
    }
  }
}


public enum ResponseResult {
  case Success(NSHTTPURLResponse)
  case Failure(NSError)
}


/// A hypermedia API client
public class Hyperdrive {
  public static var errorDomain:String {
    return "Hyperdrive"
  }

  private let session:NSURLSession

  public init() {
    let configuration = NSURLSessionConfiguration.defaultSessionConfiguration()
    session = NSURLSession(configuration: configuration)
  }

  // MARK: -

  /// Enter a hypermedia API given the root URI
  public func enter(uri:String, completion:(Result -> Void)) {
    request(uri, completion:completion)
  }

  // MARK: Subclass hooks

  /// Construct a request from a URI and parameters
  public func constructRequest(uri:String, parameters:[String:AnyObject]? = nil) -> RequestResult {
    let expandedURI = URITemplate(template: uri).expand(parameters ?? [:])

    if let URL = NSURL(string: expandedURI) {
      let request = NSMutableURLRequest(URL: URL)
      request.setValue("application/vnd.siren+json; application/hal+json", forHTTPHeaderField: "Accept")
      return .Success(request)
    }

    let error = NSError(domain: Hyperdrive.errorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Creating NSURL from given URI failed"])
    return .Failure(error)
  }

  public func constructRequest(transition:HTTPTransition, parameters:[String:AnyObject]?  = nil, attributes:[String:AnyObject]? = nil) -> RequestResult {
    return constructRequest(transition.uri, parameters:parameters).flatMap { request in
      request.HTTPMethod = transition.method

      if let attributes = attributes {
        request.HTTPBody = self.encodeAttributes(attributes, suggestedContentTypes: transition.suggestedContentTypes)
      }

      return .Success(request)
    }
  }

  func encodeAttributes(attributes:[String:AnyObject], suggestedContentTypes:[String]) -> NSData? {
    let JSONEncoder = { (attributes:[String:AnyObject]) -> NSData? in
        do {
          return try NSJSONSerialization.dataWithJSONObject(attributes, options: NSJSONWritingOptions(rawValue: 0))
        } catch _ {
          return nil
        }
    }

    let encoders:[String:([String:AnyObject] -> NSData?)] = [
      "application/json": JSONEncoder
    ]

    for contentType in suggestedContentTypes {
      if let encoder = encoders[contentType] {
        return encoder(attributes)
      }
    }

    return JSONEncoder(attributes)
  }

  public func constructResponse(request:NSURLRequest, response:NSHTTPURLResponse, body:NSData?) -> Representor<HTTPTransition>? {
    if let body = body {
      let representor = HTTPDeserialization.deserialize(response, body: body)
      if let representor = representor {
        return absoluteRepresentor(response.URL)(original: representor)
      }
    }

    return nil
  }

  // MARK: Perform requests

  func request(request:NSURLRequest, completion:(Result -> Void)) {
    let dataTask = session.dataTaskWithRequest(request, completionHandler: { (body, response, error) -> Void in
      if let error = error {
        dispatch_async(dispatch_get_main_queue()) {
          completion(.Failure(error))
        }
      } else {
        let representor = self.constructResponse(request, response:response as! NSHTTPURLResponse, body: body) ?? Representor<HTTPTransition>()
        dispatch_async(dispatch_get_main_queue()) {
          completion(.Success(representor))
        }
      }
    })

    dataTask.resume()
  }

  /// Perform a request with a given URI and parameters
  public func request(uri:String, parameters:[String:AnyObject]? = nil, completion:(Result -> Void)) {
    switch constructRequest(uri, parameters: parameters) {
    case .Success(let request):
      self.request(request, completion:completion)
    case .Failure(let error):
      completion(.Failure(error))
    }
  }

  /// Perform a transition with a given parameters and attributes
  public func request(transition:HTTPTransition, parameters:[String:AnyObject]? = nil, attributes:[String:AnyObject]? = nil, completion:(Result -> Void)) {
    let result = constructRequest(transition, parameters: parameters, attributes: attributes)

    switch result {
    case .Success(let request):
      self.request(request, completion:completion)
    case .Failure(let error):
      completion(.Failure(error))
    }
  }
}
