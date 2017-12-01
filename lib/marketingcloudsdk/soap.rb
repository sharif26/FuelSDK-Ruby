=begin
Copyright (c) 2013 ExactTarget, Inc.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the

following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the

following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the

following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote

products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,

INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE

DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,

SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR

SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,

WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE

USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
=end

require 'savon'
module MarketingCloudSDK
	# Represents SOAP Response from API call using Salesforce Marketing Cloud	
	class SoapResponse < MarketingCloudSDK::Response
		# Continue if there is more data available in the response
		# @return The continued SOAP response
		def continue
			rsp = nil
			if more?
				rsp = unpack @client.soap_client.call(:retrieve, :message => {'ContinueRequest' => request_id})
			else
				puts 'No more data'
			end

			rsp
		end

		private
		def unpack_body raw
			@body = raw.body
			@request_id = raw.body[raw.body.keys.first][:request_id]
			unpack_msg raw
		rescue
			@message = raw.http.body
			@body = raw.http.body unless @body
		end

		def unpack raw
			@code = raw.http.code
			unpack_body raw
			@success = @message == 'OK'
			@results += (unpack_rslts raw)
		end

		def unpack_msg raw
			@message = raw.soap_fault? ? raw.body[:fault][:faultstring] : raw.body[raw.body.keys.first][:overall_status]
		end

		def unpack_rslts raw
			@more = (raw.body[raw.body.keys.first][:overall_status] == 'MoreDataAvailable')
			rslts = raw.body[raw.body.keys.first][:results] || []
			rslts = [rslts] unless rslts.kind_of? Array
			rslts
		rescue
			[]
		end
	end

	# Represents Describe SOAP Response from API call using Salesforce Marketing Cloud	
	class DescribeResponse < SoapResponse
		attr_reader :properties, :retrievable, :updatable, :required, :extended, :viewable, :editable
		
		private
		def unpack_rslts raw
			@retrievable, @updatable, @required, @properties, @extended, @viewable, @editable = [], [], [], [], [], [], [], []
			definition = raw.body[raw.body.keys.first][:object_definition]
			_props = definition[:properties]
			_props.each do  |p|
				@retrievable << p[:name] if p[:is_retrievable] and (p[:name] != 'DataRetentionPeriod')
				@updatable << p[:name] if p[:is_updatable]
				@required << p[:name] if p[:is_required]
				@properties << p[:name]
			end
			# ugly, but a necessary evil
			_exts = definition[:extended_properties].nil? ? {} : definition[:extended_properties] # if they have no extended properties nil is returned
			_exts = _exts[:extended_property] || [] # if no properties nil and we need an array to iterate
			_exts = [_exts] unless _exts.kind_of? Array # if they have only one extended property we need to wrap it in array to iterate
			_exts.each do  |p|
				@viewable << p[:name] if p[:is_viewable]
				@editable << p[:name] if p[:is_editable]
				@extended << p[:name]
			end
			@success = true # overall_status is missing from definition response, so need to set here manually
			_props + _exts
		rescue
			@message = "Unable to describe #{raw.locals[:message]['DescribeRequests']['ObjectDefinitionRequest']['ObjectType']}"
			@success = false
			[]
		end
	end

	module Soap
		attr_accessor :wsdl, :debug#, :internal_token

		include MarketingCloudSDK::Targeting

		# Method to support legacy SOAP header
		def header
			raise 'Require legacy token for soap header' unless internal_token
			{
				'oAuth' => {'oAuthToken' => internal_token},
				:attributes! => { 'oAuth' => { 'xmlns' => 'http://exacttarget.com' }}
			}
		end

		# Assigns the debug property, by default false
		def debug
			@debug ||= false
		end

		# Assigns the wsdl property with default URL
		def wsdl
			@wsdl ||= 'https://webservice.exacttarget.com/etframework.wsdl'
		end

		# Initialize the Savon soap client
		def soap_client
			self.refresh
			@soap_client = Savon.client(
				soap_header: header,
				wsdl: wsdl,
				endpoint: endpoint,
				wsse_auth: ["*", "*"],
				raise_errors: false,
				log: debug,
				open_timeout:180,
				read_timeout: 180
			)
		end

		def soap_describe object_type
			message = {
				'DescribeRequests' => {
					'ObjectDefinitionRequest' => {
						'ObjectType' => object_type
					}
				}
			}
			soap_request :describe, message
		end

		# Executes the SOAP PERFORM operation
		# @param String object_type 	The type of the object, e.g. "ImportDefinition", "DataExtension", etc
		# @param String action 			The action to perform, e.g. "create", "delete", "update", etc
		# @param Hash 	properties		The properties is passed to do the SOAP PERFORM operation e.g. {'id' => '', 'key' => ''}
		# @return  The response after doing the SOAP PERFORM operation
		def soap_perform object_type, action, properties
			message = {}
			message['Action'] = action
			message['Definitions'] = {'Definition' => properties}
			message['Definitions'][:attributes!] = { 'Definition' => { 'xsi:type' => ('tns:' + object_type) }}

			soap_request :perform, message
		end

		# Executes the SOAP Configurations operation
		# @param String object_type 	The type of the object, e.g. "PropertyDefinition", "Role", etc
		# @param String action 			The action to configure, e.g. "create", "delete", "update", etc
		# @param Hash 	properties		The properties is passed to do the SOAP Configurations operation e.g. {'id' => '', 'key' => ''}
		# @return  The response after doing the SOAP Configurations operation
		def soap_configure  object_type, action, properties
			message = {}
			message['Action'] = action
			message['Configurations'] = {}
			if properties.is_a? Array then
				message['Configurations']['Configuration'] = []
				properties.each do |configItem|
					message['Configurations']['Configuration'] << configItem
				end
			else
				message['Configurations'] = {'Configuration' => properties}
			end
			message['Configurations'][:attributes!] = { 'Configuration' => { 'xsi:type' => ('tns:' + object_type) }}

			soap_request :configure, message
		end

		# Executes the SOAP Retrieve operation
		# @param String object_type 	The type of the object, e.g. "Email", "TriggeredSend", etc
		# @param Hash filter 			The filter to get, e.g. {"Property"=>"", "SimpleOperator"=>"","Value"=>""}
		# @param Hash 	properties		The properties is passed to do the SOAP Retrieve operation e.g. {'id' => '', 'key' => ''}
		# @return  The response after doing the SOAP GET operation
		def soap_get object_type, properties=nil, filter=nil
			if properties.nil? or properties.empty?
				rsp = soap_describe object_type
				if rsp.success?
					properties = rsp.retrievable
				else
					rsp.instance_variable_set(:@message, "Unable to get #{object_type}") # back door update
					return rsp
				end
			elsif properties.kind_of? Hash
				properties = properties.keys
			elsif properties.kind_of? String
				properties = [properties]
			end

			message = {'ObjectType' => object_type, 'Properties' => properties}

			if filter and filter.kind_of? Hash
				message['Filter'] = filter
				message[:attributes!] = { 'Filter' => { 'xsi:type' => 'tns:SimpleFilterPart' } }

				if filter.has_key?('LogicalOperator')
					message[:attributes!] = { 'Filter' => { 'xsi:type' => 'tns:ComplexFilterPart' }}
					message['Filter'][:attributes!] = {
						'LeftOperand' => { 'xsi:type' => 'tns:SimpleFilterPart' },
					'RightOperand' => { 'xsi:type' => 'tns:SimpleFilterPart' }}
				end
			end
			message = {'RetrieveRequest' => message}

			soap_request :retrieve, message
		end

		# Executes the SOAP POST operation
		# @param String object_type 	The type of the object, e.g. "Email", "TriggeredSend", etc
		# @param Hash 	properties		The properties is passed to do the SOAP POST operation e.g. {'id' => '', 'key' => ''}
		# @return  The response after doing the SOAP POST operation
		def soap_post object_type, properties
			soap_cud :create, object_type, properties
		end

		# Executes the SOAP PATCH operation
		# @param String object_type 	The type of the object, e.g. "Email", "TriggeredSend", etc
		# @param Hash 	properties		The properties is passed to do the SOAP PATCH operation e.g. {'id' => '', 'key' => ''}
		# @return  The response after doing the SOAP PATCH operation
		def soap_patch object_type, properties
			soap_cud :update, object_type, properties
		end

		# Executes the SOAP DELETE operation
		# @param String object_type 	The type of the object, e.g. "Email", "TriggeredSend", etc
		# @param Hash 	properties		The properties is passed to do the SOAP DELETE operation e.g. {'id' => '', 'key' => ''}
		# @return  The response after doing the SOAP DELETE operation
		def soap_delete object_type, properties
			soap_cud :delete, object_type, properties
		end

		# Executes the SOAP PUT operation
		# @param String object_type 	The type of the object, e.g. "Email", "TriggeredSend", etc
		# @param Hash 	properties		The properties is passed to do the SOAP PUT operation e.g. {'id' => '', 'key' => ''}
		# @return  The response after doing the SOAP PUT operation
		def soap_put object_type, properties
			soap_cud :update, object_type, properties, true
		end

		private
		def soap_cud action, object_type, properties, upsert=nil
			# get a list of attributes so we can seperate
			# them from standard object properties
			#type_attrs = soap_describe(object_type).editable

			#
			#   properties = [properties] unless properties.kind_of? Array
			#   properties.each do |p|
			#     formated_attrs = []
			#     p.each do |k, v|
			#       if type_attrs.include? k
			#         p.delete k
			#         attrs = MarketingCloudSDK.format_name_value_pairs k => v
			#         formated_attrs.concat attrs
			#       end
			#     end
			#     (p['Attributes'] ||= []).concat formated_attrs unless formated_attrs.empty?
			#   end
			#

			message = {
				'Objects' => properties,
				:attributes! => { 'Objects' => { 'xsi:type' => ('tns:' + object_type) } }
			}

			if upsert
				message['Options'] = {"SaveOptions" => {"SaveOption" => {"PropertyName"=> "*", "SaveAction" => "UpdateAdd"}}}
			end

			soap_request action, message
		end

		def soap_request action, message
			response = action.eql?(:describe) ? DescribeResponse : SoapResponse

			rsp = soap_client.call(action, :message => message)
			response.new rsp, self
		end
	end
end
