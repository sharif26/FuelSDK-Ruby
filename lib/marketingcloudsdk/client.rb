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

require 'securerandom'
module MarketingCloudSDK
	# Represents Response from API call for Salesforce Marketing Cloud
	class Response
		# not doing accessor so user, can't update these values from response.
		# You will see in the code some of these
		# items are being updated via back doors and such.
		attr_reader :code, :message, :results, :request_id, :body, :raw
		
		# Checks the status of the response
		# @return true if successfull response, false otherwise
		def success
			@success ||= false
		end
		alias :success? :success
		alias :status :success # backward compatibility

		# Checks if there is more data available in the response
		# @return true if more response available, false otherwise
		def more
			@more ||= false
		end
		alias :more? :more

		# Initialize the Response object
		# @param client Client the Client object
		# @param raw the raw response from API call
		def initialize raw, client
			@client = client # keep connection with client in case we request more
			@results = []
			@raw = raw
			unpack raw
		rescue => ex # all else fails return raw
			puts ex.message
			raw
		end

		# Should handle the continue feature in the child class
		def continue
			raise NotImplementedError
		end

		private
		def unpack raw
		raise NotImplementedError
		end
	end
	
	# Represents Rest or Soap client for Salesforce Marketing Cloud
	class Client
	attr_accessor :debug, :access_token, :auth_token, :internal_token, :refresh_token,
		:id, :secret, :signature, :package_name, :package_folders, :parent_folders, :auth_token_expiration, :request_token_url

	include MarketingCloudSDK::Soap
	include MarketingCloudSDK::Rest

		# Custom code to assign jwt
		# @param string encoded_jwt The encoded jwt value
		def jwt= encoded_jwt
			raise 'Require app signature to decode JWT' unless self.signature
			decoded_jwt = JWT.decode(encoded_jwt, self.signature, true)
			decoded_jwt = decoded_jwt[0]
			puts decoded_jwt.inspect
			self.auth_token = decoded_jwt['request']['user']['oauthToken']
			self.internal_token = decoded_jwt['request']['user']['internalOauthToken']
			self.refresh_token = decoded_jwt['request']['user']['refreshToken']
			self.auth_token_expiration = Time.new + decoded_jwt['request']['user']['expiresIn']
			self.package_name = decoded_jwt['request']['application']['package']
		end

		# Initializes a new instance of the Client class.
		# @param Boolean debug Flag to indicate whether debug information needs to be logged. 
		# Logging is enabled when the value is set to true and disabled when set to false.
		# @param Hash params Hash of settings as string.</br>
		def initialize(params={}, debug=false)
			@refresh_mutex = Mutex.new
			self.debug = debug
			self.request_token_url = params['request_token_url'] ? params['request_token_url'] : 'https://auth.exacttargetapis.com/v1/requestToken'

			client_config = params['client']
			if client_config
				self.id = client_config["id"]
				self.secret = client_config["secret"]
				self.signature = client_config["signature"]
				if client_config["request_token_url"]
					self.request_token_url = client_config["request_token_url"]
				end
			end

	      	# self.request_token_url = params['request_token_url'] ? params['request_token_url'] : 'https://auth.exacttargetapis.com/v1/requestToken'
			self.jwt = params['jwt'] if params['jwt']
			self.refresh_token = params['refresh_token'] if params['refresh_token']
			self.wsdl = params["defaultwsdl"] if params["defaultwsdl"]
		end

		# Gets the refresh token using the authentication URL.
		# @param Boolean force Flag to indicate a force refresh of authentication toekn.
		# @return Boolean returns true if the new access token is found, false otherwise.
		def refresh force=false
			@refresh_mutex.synchronize do
				raise 'Require Client Id and Client Secret to refresh tokens' unless (id && secret)
				#If we don't already have a token or the token expires within 5 min(300 seconds)
				if (self.access_token.nil? || Time.new + 300 > self.auth_token_expiration || force) then
				payload = Hash.new.tap do |h|
					h['clientId']= id
					h['clientSecret'] = secret
					h['refreshToken'] = refresh_token if refresh_token
					h['accessType'] = 'offline'
				end

				options = Hash.new.tap do |h|
					h['data'] = payload
					h['content_type'] = 'application/json'
					h['params'] = {'legacy' => 1}
				end
				response = post(request_token_url, options)
				raise "Unable to refresh token: #{response['message']}" unless response.has_key?('accessToken')

				self.access_token = response['accessToken']
				self.internal_token = response['legacyToken']
				self.auth_token_expiration = Time.new + response['expiresIn']
				self.refresh_token = response['refreshToken'] if response.has_key?("refreshToken")
				return true
				else 
				return false
				end
			end
		end

		def refresh!
			refresh true
		end

		# Add subscriber to list.
		# @param string email Email address of the subscriber
		# @param Array ids Array of list id to which the subscriber is added
		# @param string subscriber_key Newly added subscriber key
		# @return The post response object
		def AddSubscriberToList(email, ids, subscriber_key = nil)
			s = MarketingCloudSDK::Subscriber.new
			s.client = self
			lists = ids.collect{|id| {'ID' => id}}
			s.properties = {"EmailAddress" => email, "Lists" => lists}
			p s.properties 
			s.properties['SubscriberKey'] = subscriber_key if subscriber_key

			# Try to add the subscriber
			if(rsp = s.post and rsp.results.first[:error_code] == '12014')
			# subscriber already exists we need to update.
			rsp = s.patch
			end
			rsp
		end

		# Create a new data extension based on the definitions passed
		# @param array definitions Data extension definition properties as an array
		# @return mixed post response object
		def CreateDataExtensions(definitions)
			de = MarketingCloudSDK::DataExtension.new
			de.client = self
			de.properties = definitions
			de.post
		end

		# Starts an send operation for the TriggerredSend records
		# @param array arrayOfTriggeredRecords Array of TriggeredSend records
		# @return The Send reponse object
		def SendTriggeredSends(arrayOfTriggeredRecords)
			sendTS = ET_TriggeredSend.new
			sendTS.authStub = self
			
			sendTS.properties = arrayOfTriggeredRecords
			sendResponse = sendTS.send
			
			return sendResponse
		end

		# Create an email send definition, send the email based on the definition and delete the definition.
		# @param string emailID Email identifier for which the email is sent
		# @param string listID Send definition list identifier
		# @param string sendClassficationCustomerKey Send classification customer key 
		# @return The send reponse object
		def SendEmailToList(emailID, listID, sendClassificationCustomerKey)
			email = ET_Email::SendDefinition.new 
			email.properties = {"Name"=>SecureRandom.uuid, "CustomerKey"=>SecureRandom.uuid, "Description"=>"Created with RubySDK"} 
			email.properties["SendClassification"] = {"CustomerKey"=>sendClassificationCustomerKey}
			email.properties["SendDefinitionList"] = {"List"=> {"ID"=>listID}, "DataSourceTypeID"=>"List"}
			email.properties["Email"] = {"ID"=>emailID}
			email.authStub = self
			result = email.post
			if result.status then 
				sendresult = email.send 
				if sendresult.status then 
					deleteresult = email.delete
					return sendresult
				else 
					raise "Unable to send using send definition due to: #{result.results[0][:status_message]}"
				end 
			else
				raise "Unable to create send definition due to: #{result.results[0][:status_message]}"
			end 
		end 

		# Create an email send definition, send the email based on the definition and delete the definition.
		# @param string emailID Email identifier for which the email is sent
		# @param string sendableDataExtensionCustomerKey Sendable data extension customer key 
		# @param string sendClassficationCustomerKey Send classification customer key 
		# @return The send reponse object
		def SendEmailToDataExtension(emailID, sendableDataExtensionCustomerKey, sendClassificationCustomerKey)
			email = ET_Email::SendDefinition.new 
			email.properties = {"Name"=>SecureRandom.uuid, "CustomerKey"=>SecureRandom.uuid, "Description"=>"Created with RubySDK"} 
			email.properties["SendClassification"] = {"CustomerKey"=> sendClassificationCustomerKey}
			email.properties["SendDefinitionList"] = {"CustomerKey"=> sendableDataExtensionCustomerKey, "DataSourceTypeID"=>"CustomObject"}
			email.properties["Email"] = {"ID"=>emailID}
			email.authStub = self
			result = email.post
			if result.status then 
				sendresult = email.send 
				if sendresult.status then 
					deleteresult = email.delete
					return sendresult
				else 
					raise "Unable to send using send definition due to: #{result.results[0][:status_message]}"
				end 
			else
				raise "Unable to create send definition due to: #{result.results[0][:status_message]}"
			end 
		end

		# Create an import definition and start the import process
		# @param string listId List identifier. Used as the destination object identifier.
		# @param string fileName Name of the file to be imported
		# @return Returns the import process result
		def CreateAndStartListImport(listId,fileName)
			import = ET_Import.new 
			import.authStub = self
			import.properties = {"Name"=> "SDK Generated Import #{DateTime.now.to_s}"}
			import.properties["CustomerKey"] = SecureRandom.uuid
			import.properties["Description"] = "SDK Generated Import"
			import.properties["AllowErrors"] = "true"
			import.properties["DestinationObject"] = {"ID"=>listId}
			import.properties["FieldMappingType"] = "InferFromColumnHeadings"
			import.properties["FileSpec"] = fileName
			import.properties["FileType"] = "CSV"
			import.properties["RetrieveFileTransferLocation"] = {"CustomerKey"=>"ExactTarget Enhanced FTP"}
			import.properties["UpdateType"] = "AddAndUpdate"
			result = import.post
			
			if result.status then 
				return import.start 
			else
				raise "Unable to create import definition due to: #{result.results[0][:status_message]}"
			end 
		end 

		# Create an import definition and start the import process
		# @param string dataExtensionCustomerKey Data extension customer key. Used as the destination object identifier.
		# @param string fileName Name of the file to be imported
		# @param Boolean overwrite Flag to indicate to overwrite the uploaded file
		# @return Returns the import process result
		def CreateAndStartDataExtensionImport(dataExtensionCustomerKey, fileName, overwrite)
			import = ET_Import.new 
			import.authStub = self
			import.properties = {"Name"=> "SDK Generated Import #{DateTime.now.to_s}"}
			import.properties["CustomerKey"] = SecureRandom.uuid
			import.properties["Description"] = "SDK Generated Import"
			import.properties["AllowErrors"] = "true"
			import.properties["DestinationObject"] = {"CustomerKey"=>dataExtensionCustomerKey}
			import.properties["FieldMappingType"] = "InferFromColumnHeadings"
			import.properties["FileSpec"] = fileName
			import.properties["FileType"] = "CSV"
			import.properties["RetrieveFileTransferLocation"] = {"CustomerKey"=>"ExactTarget Enhanced FTP"}
			if overwrite then
				import.properties["UpdateType"] = "Overwrite"
			else 
				import.properties["UpdateType"] = "AddAndUpdate"
			end 
			result = import.post
			
			if result.status then 
				return import.start 
			else
				raise "Unable to create import definition due to: #{result.results[0][:status_message]}"
			end 
		end 
			
		# Create a profile attribute
		# @param array $allAttributes Profile attribute properties as an array.
		# @return the post response object
		def CreateProfileAttributes(allAttributes)
			attrs = ET_ProfileAttribute.new 
			attrs.authStub = self
			attrs.properties = allAttributes
			return attrs.post
		end

		# Create one or more content areas
		# @param array $arrayOfContentAreas Content areas properties as an array
		# @return the post response object
		def CreateContentAreas(arrayOfContentAreas)
			postC = ET_ContentArea.new
			postC.authStub = self
			postC.properties = arrayOfContentAreas
			sendResponse = postC.post			
			return sendResponse
		end
	end
end
