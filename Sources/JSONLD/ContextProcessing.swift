//
//  ContextProcessing.swift
//  JSONLD
//
//  Created by GWilliams on 3/16/20.
//

import Foundation

public extension JSONLD {
	func preprocessContext(_ expandContext: JSON) throws -> Context {
		var ctx = newContext(base: self.base)
		var ec = expandContext
		if let _ec = ec["@context"] {
			ec = _ec
		}
		let base: URL
		if case let .string(s) = expandContext.value, let u = URL(string: s) {
			base = u
		} else {
			base = self.base
		}
		return try _4_1_2_ctx_processing(activeCtx: &ctx, localCtx: ec, base: base)
	}

	func preprocessContext(_ url: URL) throws -> Context {
		var ctx = newContext(base: self.base)
		let expandContext = try getRemoteContext(from: url)
		let base = self.base
		return try _4_1_2_ctx_processing(activeCtx: &ctx, localCtx: expandContext, base: base)
	}
}

let gen_delims = Set<Character>("[]:/?#@$")

extension JSONLD {
	func getRemoteContext(from url: URL) throws -> JSON {
		let (_data, _, error) = loadDocument(url: url, profile: "http://www.w3.org/ns/json-ld#context", requestProfile: ["http://www.w3.org/ns/json-ld#context"])
		if let error = error {
			try apiError(.loading_remote_context_failed(error))
		}
		guard let data = _data else {
			try apiError(.loading_remote_context_failed(nil))
		}
		guard let j = JSON.decode(data), let context = j["@context"] else {
			try apiError(.loading_remote_context_failed(nil))
		}
		return context
	}

	@discardableResult
	func _4_1_2_ctx_processing(activeCtx: inout Context, localCtx: JSON, base: URL? = nil, remoteContexts: [URL] = [], overrideProtected: Bool = false, propagate: Bool = true) throws -> Context {
		let base = base ?? self.base
		var propagate = propagate
		var localCtx = localCtx
		var result = activeCtx.clone()
		if localCtx.is_map && localCtx.has(key: "@propagate") {
			propagate = localCtx["@propagate", default: JSON.null].booleanValue
		}

		if !propagate && result.previousContext == nil {
			result.previousContext = activeCtx
		}

		localCtx = localCtx.as_array
		for context in localCtx.values_from_scalar_or_array {
			var context = context
			if !context.defined {
				// # 5.1
				if !overrideProtected && activeCtx.containsProtectedTerms {
					try apiError(.invalid_context_nullification)
				} else {
					let prev = result
					result = Context(originalBaseURL: self.base, base: self.base) // TODO: not sure this follows the spec, but it's what makes test t0089 pass
					if propagate {
						result.previousContext = prev
					}
					continue
				}
			}

			if let s = context.stringValue, let context_url = URL(string: s, relativeTo: base) {
				let contextString = context_url.absoluteString
				context = JSON.wrap(contextString)
				if remoteContexts.count > maxRemoteContexts {
					try apiError(.context_overflow)
				}

				if let c = parsedRemoteContexts[context_url] {
					context = c
				} else {
					let context = try getRemoteContext(from: context_url)
					parsedRemoteContexts[context_url] = context
				}

				result = try _4_1_2_ctx_processing(activeCtx: &result, localCtx: context, base: context_url, remoteContexts: remoteContexts)
				continue
			}

			if !context.is_map {
				try apiError(.invalid_local_context)
			}

			if let v = context["@version"] {
				if v.doubleValue != 1.1 {
					try apiError(.invalid_version_value(v))
				}
				if processingMode == .json_ld_10 {
					try apiError(.processing_mode_conflict)
				}
			}

			if let value = context["@import"] {
				if processingMode == .json_ld_10 {
					try apiError(.invalid_context_entry)
				}

				guard let valueString = value.stringValue else {
					try apiError(.invalid_import_value)
				}

				guard let _import = URL(string: valueString, relativeTo: self.base) else {
					try apiError(.loading_remote_context_failed(nil))
				}
				//                try self.error(JSONLDError.no_remote_context_support_XXX)

				let import_context = try getRemoteContext(from: _import)
				if !import_context.is_map {
					try apiError(.invalid_remote_context)
				}

				if import_context.has(key: "@import") {
					try apiError(.invalid_context_entry)
				}

				for (k, v) in import_context.pairs {
					context[k] = v
				}
				//              %$context    = (%$import_context, %$context);
			}

			if let value = context["@base"], remoteContexts.isEmpty { // 5.7
				if !value.defined {
					result.base = nil
				} else if let v = value.stringValue, _is_absolute_iri(v) {
					result.base = URL(string: v)
				} else if let base = result.base, let v = value.stringValue, _is_absolute_iri(v) {
					result.base = URL(string: v, relativeTo: base)
				} else {
					try apiError(.invalid_base_IRI)
				}
			}

			if let value = context["@vocab"] { // 5.8
				if !value.defined {
					result.vocab = nil
				} else if let v = value.stringValue, v.hasPrefix("_") || self._is_iri(v) {
					let iri = try _5_2_2_iri_expansion(activeCtx: &result, value: value, documentRelative: true, vocab: true)
					result.vocab = iri.stringValue
				}
			}

			if let value = context["@language"] {
				if !value.defined {
					result.language = nil
				} else if let l = value.stringValue {
					result.language = l
					//                  # TODO: validate language tag against BCP47
				} else {
					try apiError(.invalid_default_language)
				}
			}

			if let value = context["@direction"] {
				if processingMode == .json_ld_10 {
					try apiError(.invalid_context_entry)
				}

				if !value.defined {
					result.direction = nil
				} else if let v = value.stringValue {
					guard let d = TextDirection(rawValue: v) else {
						try apiError(.invalid_base_direction)
					}
					result.direction = d
				}
			}

			if let p = context["@propagate"] {
				if processingMode == .json_ld_10 {
					try apiError(.invalid_context_entry)
				}

				guard p.is_boolean else {
					try apiError(.invalid_propagate_value)
				}
			}

			let defined = [String: Bool]()
			let skip = Set(["@base", "@direction", "@import", "@language", "@propagate", "@protected", "@version", "@vocab"])
			let keys = context.keys.filter { !skip.contains($0) }.sorted().reversed()
			for key in keys {
				let protected = context["@protected", default: JSON.null].booleanValue
				try _4_2_2_create_term_definition(activeCtx: &result, localCtx: context, term: key, defined: defined, base: base, protected: protected, propagate: propagate)
			}
		}

		return result
	}

	func _4_2_2_create_term_definition(activeCtx: inout Context, localCtx: JSON, term: String, defined: [String: Bool], base: URL? = nil, protected: Bool = false, overrideProtected: Bool = false, propagate _: Bool = false) throws {
		var defined = defined
		if let d = defined[term] {
			if d {
				return
			} else {
				try apiError(.cyclic_IRI_mapping)
			}
		}

		defined[term] = false
		var value = localCtx[term, default: JSON.null] // clone
		//         # NOTE: the language interaction between 4 and 5 here is a mess. Unclear what "Otherwise" applies to. Similarly with the "Otherwise" that begins 7 below.
		if processingMode == .json_ld_11, term == "@type" {
			if !value.is_map {
				try apiError(.keyword_redefinition)
			}
			let keys = value.keys.filter { $0 != "@protected" }
			if keys != ["@container"] {
				try apiError(.keyword_redefinition)
			}
			if value["@container"]?.stringValue != "@set" {
				try apiError(.keyword_redefinition)
			}
		} else {
			if JSONLDKeywords.contains(term) {
				try apiError(.keyword_redefinition)
			}
			if term.looksLikeKeyword {
				//                 warn "create term definition attempted on a term that looks like a keyword: $term\n";
				return
			}
		}

		let previousDefinition = activeCtx.definition(for: term)
		activeCtx.removeDefinition(forTerm: term)

		var simpleTerm = false
		if !value.defined {
			value = JSON.wrap(["@id": nil])
		} else if value.is_string {
			value = value.wrapped(withMapKey: "@id")
			simpleTerm = true
		} else if value.is_map {
			simpleTerm = false
		} else {
			try apiError(.invalid_term_definition)
		}

		var definition = TermDefinition(base: base ?? self.base)
		if value["@protected", default: JSON.null].booleanValue {
			definition.protected = true
			//             println "11 TODO processing mode of json-ld-1.0" if $debug;
		} else if !value.has(key: "@protected"), protected {
			definition.protected = true
		}

		if var type = value["@type"] {
			guard let typeString = type.stringValue else {
				try apiError(.invalid_type_mapping)
			}
			type = try _5_2_2_iri_expansion(activeCtx: &activeCtx, value: type, vocab: true, localCtx: localCtx, defined: defined)
			if typeString == "@json" || typeString == "@none", processingMode == .json_ld_10 {
				try apiError(.invalid_type_mapping)
			}

			if typeString != "@id", typeString != "@vocab", typeString != "@none", typeString != "@json", !_is_absolute_iri(typeString) {
				try apiError(.invalid_type_mapping)
			}
			definition.type_mapping = typeString
		}

		if let reverse = value["@reverse"] { // 14
			if value.has(key: "@id") || value.has(key: "@nest") {
				try apiError(.invalid_reverse_property)
			}
			guard let reverseString = reverse.stringValue else {
				try apiError(.invalid_IRI_mapping)
			}

			if reverseString.looksLikeKeyword {
				warning("@reverse value looks like a keyword: \(reverseString)")
				return
			} else {
				let m = try _5_2_2_iri_expansion(activeCtx: &activeCtx, value: reverse, vocab: true, localCtx: localCtx, defined: defined)
				guard let s = m.stringValue, _is_absolute_iri(s) else {
					try apiError(.invalid_IRI_mapping)
				}
				definition.iri_mapping = s
			}

			if let c = value["@container"] {
				guard !c.defined || c.stringValue == "@set" || c.stringValue == "@index" else {
					try apiError(.invalid_reverse_property)
				}

				if let s = c.stringValue {
					definition.container_mapping = [s]
				} else {
					definition.container_mapping = []
				}
			}

			definition.reverse = true
			activeCtx.addDefinition(definition, forTerm: term)
			defined[term] = true
			return
		}

		definition.reverse = false

		let termChars = Set(term)
		if let id = value["@id"], !id.defined || id.stringValue != term {
			if !id.defined {
				// 16.1
			} else {
				guard let idString = id.stringValue else {
					try apiError(.invalid_IRI_mapping)
				}

				if id.defined && !JSONLDKeywords.contains(idString) && idString.looksLikeKeyword {
					//                         warn "create term definition encountered an \@id that looks like a keyword: $id\n";
					return
				} else {
					let i = try _5_2_2_iri_expansion(activeCtx: &activeCtx, value: id, vocab: true, localCtx: localCtx, defined: defined)
					guard let iri = i.stringValue else {
						try error(.datatypeError("Expected string value from IRI expansion but got: \(i)"))
					}
					if !JSONLDKeywords.contains(iri), !_is_absolute_iri(iri), !iri.contains(":") {
						try apiError(.invalid_IRI_mapping)
					}
					if iri == "@context" {
						try apiError(.invalid_keyword_alias)
					}
					definition.iri_mapping = iri
				}

				// testing term =~ /.:./
				var has_inner_colon = false
				if let i = term.firstIndex(of: ":"), i != term.startIndex {
					has_inner_colon = true
				}
				if has_inner_colon || termChars.contains("/") {
					// 16.2.4
					defined[term] = true
					let iri = try _5_2_2_iri_expansion(activeCtx: &activeCtx, value: JSON.wrap(term), vocab: true, localCtx: localCtx, defined: defined)
					if iri.stringValue != definition.iri_mapping {
						try apiError(.invalid_IRI_mapping)
					}
				}

				let i = Set(definition.iri_mapping ?? "")
				let i_has_gen_delim = !i.intersection(gen_delims).isEmpty
				if !termChars.contains(":"), !termChars.contains("/"), simpleTerm, i_has_gen_delim {
					definition.prefix_flag = true
				}
			}
		} else if termChars.contains(":"), term.lastIndex(of: ":") != term.startIndex {
			let pair = term.split(separator: ":", maxSplits: 1)
			let prefix = String(pair[0])
			let suffix = String(pair[1])
			if localCtx.has(key: prefix) {
				try _4_2_2_create_term_definition(activeCtx: &activeCtx, localCtx: localCtx, term: prefix, defined: defined)
			}
			if let defn = activeCtx.definition(for: prefix) {
				definition.iri_mapping = (defn.iri_mapping ?? "") + suffix
			} else {
				definition.iri_mapping = term
			}
		} else if termChars.contains("/") {
			let i = try _5_2_2_iri_expansion(activeCtx: &activeCtx, value: JSON.wrap(term), vocab: true)
			definition.iri_mapping = i.stringValue
			if !_is_iri(definition.iri_mapping) {
				try apiError(.invalid_IRI_mapping)
			}
		} else if term == "@type" {
			definition.iri_mapping = "@type"
		} else {
			// 20 ; NOTE: this section uses a passive voice "the IRI mapping of definition is set to ..." cf. 18 where it's active: "set the IRI mapping of definition to @type"
			if let v = activeCtx.vocab {
				definition.iri_mapping = v + term
			} else {
				try apiError(.invalid_IRI_mapping)
			}
		}

		if let container = value["@container"] { // 21
			let acceptable: Set<String?> = ["@graph", "@id", "@index", "@language", "@list", "@set", "@type"]
			if let s = container.stringValue, acceptable.contains(s) {
			} else if container.is_array {
				let acceptable2: Set<String?> = ["@index", "@graph", "@id", "@type", "@language"]
				let values = container.values_from_scalar_or_array
				if values.count == 1 {
					let c = container[0]
					if !acceptable.contains(c?.stringValue) {
						try apiError(.invalid_container_mapping)
					}
				} else if values.anySatisfy({ $0.stringValue == "@id" || $0.stringValue == "@index" }) {
				} else if values.anySatisfy({ $0.stringValue == "@set" }), values.anySatisfy({ acceptable2.contains($0.stringValue) }) {
				} else {
					try apiError(.invalid_container_mapping)
				}
			} else {
				try apiError(.invalid_container_mapping)
			}

			if processingMode == .json_ld_10 {
				let acceptable: Set<String?> = ["@graph", "@id", "@type"]
				if acceptable.contains(container.stringValue) || !container.is_string {
					try apiError(.invalid_term_definition)
				}
			}

			if container.is_array {
				definition.container_mapping = try container.values_from_scalar_or_array.map { j in
					guard let s = j.stringValue else {
						try self.error(.datatypeError("Expected container mapping to be array of strings, but got: \(container)"))
					}
					return s
				}
			} else {
				guard let s = container.stringValue else {
					try error(.datatypeError("Expected container mapping to be a string, but got: \(container)"))
				}
				definition.container_mapping = [s]
			}

			if container.stringValue == "@type" {
				if definition.type_mapping == nil {
					definition.type_mapping = "@id"
				}
				let tm = definition.type_mapping
				if tm != "@id", tm != "@vocab" {
					try apiError(.invalid_type_mapping)
				}
			}
		}

		if let index = value["@index"] { // 22
			let container_mapping = definition.container_mapping
			if processingMode == .json_ld_10 || !container_mapping.contains("@index") {
				try apiError(.invalid_term_definition)
			}
			let expanded = try _5_2_2_iri_expansion(activeCtx: &activeCtx, value: index)
			if !_is_iri(expanded.stringValue) {
				try apiError(.invalid_term_definition)
			}
			definition.index_mapping = index.stringValue
		}

		if let context = value["@context"] {
			if processingMode == .json_ld_10 {
				try apiError(.invalid_term_definition)
			}
			try _4_1_2_ctx_processing(activeCtx: &activeCtx, localCtx: context, base: base, overrideProtected: true)
			definition.context = context
		}

		if let language = value["@language"], !value.has(key: "@type") {
			// 24
			if !(!language.defined || language.is_string) {
				try apiError(.invalid_language_mapping)
			}
			//             # TODO: validate language tag against BCP47
			//             # TODO: normalize language tag
			definition.language_mapping = language.stringValue
		}

		if let direction = value["@direction"], !value.has(key: "@type") { // 25
			if !direction.defined {
			} else if direction.stringValue != "ltr", direction.stringValue != "rtl" {
				try apiError(.invalid_base_direction)
			}

			if let s = direction.stringValue, let d = TextDirection(rawValue: s) {
				definition.direction_mapping = d
			} else {
				definition.direction_mapping = nil
			}
		}

		if let nv = value["@nest"] {
			if processingMode == .json_ld_10 {
				try apiError(.invalid_term_definition)
			}
			if !nv.defined || !nv.is_string {
				try apiError(.invalid_nest_value)
			} else if JSONLDKeywords.contains(nv.stringValue ?? ""), nv.stringValue != "@nest" {
				try apiError(.invalid_nest_value)
			}
			definition.nest_value = nv.stringValue
		}

		if let prefix = value["@prefix"] {
			if processingMode == .json_ld_10 || term.contains(":") || term.contains("/") {
				try apiError(.invalid_term_definition)
			}
			definition.prefix_flag = prefix.booleanValue
			//             # TODO: check if this value is a boolean. if it is NOT, die 'invalid @prefix value';

			if definition.prefix_flag, JSONLDKeywords.contains(definition.iri_mapping ?? "") {
				try apiError(.invalid_term_definition)
			}
		}

		let skip = Set(["@id", "@reverse", "@container", "@context", "@language", "@nest", "@prefix", "@type", "@direction", "@protected", "@index"])
		let keys = Set(value.keys).subtracting(skip)
		if !keys.isEmpty {
			print("invalid keys: \(keys)")
			try apiError(.invalid_term_definition)
		}

		if let prev = previousDefinition, !overrideProtected, prev.protected { // 29
			if !definition.equalsIgnoringProtected(prev) {
				try apiError(.protected_term_redefinition)
			}
			definition = prev
		}

		activeCtx.addDefinition(definition, forTerm: term)
		defined[term] = true
	}
}
