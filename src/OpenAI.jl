module OpenAI

using JSON3
using HTTP
using Dates

abstract type AbstractOpenAIProvider end
Base.@kwdef struct OpenAIProvider <: AbstractOpenAIProvider
    api_key::String = ""
    base_url::String = "https://api.openai.com/v1"
    api_version::String = ""
end
Base.@kwdef struct AzureProvider <: AbstractOpenAIProvider
    api_key::String = ""
    base_url::String = "https://docs-test-001.openai.azure.com/openai/deployments/gpt-35-turbo"
    api_version::String = "2023-03-15-preview"
end

"""
    DEFAULT_PROVIDER

Default provider for OpenAI API requests.
"""
const DEFAULT_PROVIDER = let
    api_key = get(ENV, "OPENAI_API_KEY", nothing)
    if api_key === nothing
        OpenAIProvider()
    else
        OpenAIProvider(api_key=api_key)
    end
end

"""
    auth_header(provider::AbstractOpenAIProvider, api_key::AbstractString)

Return the authorization header for the given provider and API key.
"""
auth_header(provider::AbstractOpenAIProvider) = auth_header(provider, provider.api_key)
function auth_header(::OpenAIProvider, api_key::AbstractString)
    isempty(api_key) && throw(ArgumentError("api_key cannot be empty"))
    [
        "Authorization" => "Bearer $api_key",
        "Content-Type" => "application/json"
    ]
end
function auth_header(::AzureProvider, api_key::AbstractString)
    isempty(api_key) && throw(ArgumentError("api_key cannot be empty"))
    [
        "api-key" => api_key,
        "Content-Type" => "application/json"
    ]
end

"""
    build_url(provider::AbstractOpenAIProvider, api::AbstractString)

Return the URL for the given provider and API.
"""
build_url(provider::AbstractOpenAIProvider) = build_url(provider, provider.api)
function build_url(provider::OpenAIProvider, api::String)
    isempty(api) && throw(ArgumentError("api cannot be empty"))
    "$(provider.base_url)/$(api)"
end
function build_url(provider::AzureProvider, api::String)
    isempty(api) && throw(ArgumentError("api cannot be empty"))
    (; base_url, api_version) = provider
    return "$(base_url)/$(api)?api-version=$(api_version)"
end

function build_params(kwargs)
    isempty(kwargs) && return nothing
    buf = IOBuffer()
    JSON3.write(buf, kwargs)
    seekstart(buf)
    return buf
end

function request_body(url, method; input, headers, kwargs...)
    input = input === nothing ? [] : input
    resp = HTTP.request(method, url; body=input, headers=headers, kwargs...)
    return resp, resp.body
end

function request_body_live(url; method, input, headers, streamcallback, kwargs...)
    resp = nothing

    body = sprint() do output
        resp = HTTP.open("POST", url, headers) do stream

            body = String(take!(input))
            write(stream, body)

            HTTP.closewrite(stream)    # indicate we're done writing to the request

            r = HTTP.startread(stream) # start reading the response
            isdone = false

            while !eof(stream) || !isdone
                # Extract all available messages
                masterchunk = String(readavailable(stream))

                # Split into subchunks on newlines.
                # Occasionally, the streaming will append multiple messages together,
                # and iterating through each line in turn will make sure that
                # streamingcallback is called on each message in turn.
                chunks = String.(filter(!isempty, split(masterchunk, "\n")))

                # Iterate through each chunk in turn.
                for chunk in chunks
                    if occursin(chunk, "data: [DONE]")  # TODO - maybe don't strip, but instead us a regex in the endswith call
                        isdone = true
                    end

                    # call the callback (if present) on the latest chunk
                    if !isnothing(streamcallback)
                        streamcallback(chunk)
                    end

                    # append the latest chunk to the body
                    print(output, chunk)
                end
            end
            HTTP.closeread(stream)
        end
    end

    return resp, body
end

function status_error(resp, log=nothing)
    logs = !isnothing(log) ? ": $log" : ""
    error("request status $(resp.message)$logs")
end

function _request(api::AbstractString, provider::AbstractOpenAIProvider, api_key::AbstractString=provider.api_key; method, http_kwargs, streamcallback=nothing, kwargs...)
    # add stream: True to the API call if a stream callback function is passed
    if !isnothing(streamcallback)
        kwargs = (kwargs..., stream=true)
    end

    params = build_params(kwargs)
    url = build_url(provider, api)
    resp, body = let
        if isnothing(streamcallback)
            request_body(url, method; input=params, headers=auth_header(provider, api_key), http_kwargs...)
        else
            request_body_live(url; method, input=params, headers=auth_header(provider, api_key), streamcallback=streamcallback, http_kwargs...)
        end
    end
    if resp.status >= 400
        status_error(resp, body)
    else
        return if isnothing(streamcallback)
            OpenAIResponse(resp.status, JSON3.read(body))
        else
            # assemble the streaming response body into a proper JSON object
            lines = split(body, "\n") # split body into lines

            # throw out empty lines, skip "data: [DONE] bits
            lines = filter(x -> !isempty(x) && !occursin("[DONE]", x), lines)

            # read each line, which looks like "data: {<json elements>}"
            parsed = map(line -> JSON3.read(line[6:end]), lines)

            OpenAIResponse(resp.status, parsed)
        end

    end
end

function openai_request(api::AbstractString, api_key::AbstractString; method, http_kwargs, streamcallback=nothing, kwargs...)
    global DEFAULT_PROVIDER
    _request(api, DEFAULT_PROVIDER, api_key; method, http_kwargs, streamcallback=streamcallback, kwargs...)
end

function openai_request(api::AbstractString, provider::AbstractOpenAIProvider; method, http_kwargs, streamcallback=nothing, kwargs...)
    _request(api, provider; method, http_kwargs, streamcallback=streamcallback, kwargs...)
end

struct OpenAIResponse{R}
    status::Int16
    response::R
end

"""
Default model ID for embeddings.
Follows recommendation in OpenAI docs at <https://platform.openai.com/docs/models/embeddings>.
"""
const DEFAULT_EMBEDDING_MODEL_ID = "text-embedding-ada-002"

"""
List models

# Arguments:
- `api_key::String`: OpenAI API key

For additional details, visit <https://platform.openai.com/docs/api-reference/models/list>
"""
function list_models(api_key::String; http_kwargs::NamedTuple=NamedTuple())
    return openai_request("models", api_key; method="GET", http_kwargs=http_kwargs)
end

"""
Retrieve model

# Arguments:
- `api_key::String`: OpenAI API key
- `model_id::String`: Model id

For additional details, visit <https://platform.openai.com/docs/api-reference/models/retrieve>
"""
function retrieve_model(api_key::String, model_id::String; http_kwargs::NamedTuple=NamedTuple())
    return openai_request("models/$(model_id)", api_key; method="GET", http_kwargs=http_kwargs)
end

"""
Create completion

# Arguments:
- `api_key::String`: OpenAI API key
- `model_id::String`: Model id

# Keyword Arguments (check the OpenAI docs for the exhaustive list):
- `temperature::Float64=1.0`: What sampling temperature to use, between 0 and 2. Higher values like 0.8 will make the output more random, while lower values like 0.2 will make it more focused and deterministic. We generally recommend altering this or top_p but not both.
- `top_p::Float64=1.0`: An alternative to sampling with temperature, called nucleus sampling, where the model considers the results of the tokens with top_p probability mass. So 0.1 means only the tokens comprising the top 10% probability mass are considered. We generally recommend altering this or temperature but not both.

For more details about the endpoint and additional arguments, visit <https://platform.openai.com/docs/api-reference/completions>

# HTTP.request keyword arguments:
- `http_kwargs::NamedTuple=NamedTuple()`: Keyword arguments to pass to HTTP.request (e. g., `http_kwargs=(connection_timeout=2,)` to set a connection timeout of 2 seconds).
"""
function create_completion(api_key::String, model_id::String; http_kwargs::NamedTuple=NamedTuple(), kwargs...)
    return openai_request("completions", api_key; method="POST", http_kwargs=http_kwargs, model=model_id, kwargs...)
end


"""
Checking for JSON validity of the response body used in the stream
"""
isvalidjson(str) =
    try
        JSON3.read(str)
        true
    catch
        false
    end


"""
Default streamcallback function for create_<action> functions.
"""
function wordstream(chunk)

    # Regex to match the content value if the string is not valid JSON
    regex = r""""content":"(.*?)"(?=[,}])"""

    # Process each line of the string
    for line in split(strip(chunk), "\n")
        # Remove 'data: ' prefix before checking if the line is JSON
        json_str = replace(line, r"^data:\s+" => "")

        if isvalidjson(json_str)
            # If it's valid JSON, parse it and extract the content value
            json_obj = JSON3.read(json_str)

            if typeof(json_obj) == JSON3.Object{Base.CodeUnits{UInt8,String},Vector{UInt64}} && haskey(json_obj, "choices")
                choices = json_obj.choices
                if haskey(choices[1], "delta") && haskey(choices[1].delta, "content")
                    content = choices[1].delta.content
                    print("$content")
                else
                    print("END")
                end
            end
        else
            # Otherwise, apply the regex pattern
            m = match(regex, json_str)
            if m !== nothing
                content = m.captures[1]
                print("$content")
            end
        end
    end
end


"""
Create chat

# Arguments:
- `api_key::String`: OpenAI API key
- `model_id::String`: Model id
- `messages::Vector`: The chat history so far.
- `streamcallback=nothing`: Function to call on each chunk (delta) of the chat response in streaming mode.

# Keyword Arguments (check the OpenAI docs for the exhaustive list):
- `temperature::Float64=1.0`: What sampling temperature to use, between 0 and 2. Higher values like 0.8 will make the output more random, while lower values like 0.2 will make it more focused and deterministic. We generally recommend altering this or top_p but not both.
- `top_p::Float64=1.0`: An alternative to sampling with temperature, called nucleus sampling, where the model considers the results of the tokens with top_p probability mass. So 0.1 means only the tokens comprising the top 10% probability mass are considered. We generally recommend altering this or temperature but not both.

!!! note
    Do not use `stream=true` option here, instead use the `streamcallback` keyword argument (see the relevant section below).

For more details about the endpoint and additional arguments, visit <https://platform.openai.com/docs/api-reference/chat>

# HTTP.request keyword arguments:
- `http_kwargs::NamedTuple=NamedTuple()`: Keyword arguments to pass to HTTP.request (e. g., `http_kwargs=(connection_timeout=2,)` to set a connection timeout of 2 seconds).

## Example:

```julia
julia> CC = create_chat("..........", "gpt-3.5-turbo", 
    [Dict("role" => "user", "content"=> "What is the OpenAI mission?")]
);

julia> CC.response.choices[1][:message][:content]
"\n\nThe OpenAI mission is to create safe and beneficial artificial intelligence (AI) that can help humanity achieve its full potential. The organization aims to discover and develop technical approaches to AI that are safe and aligned with human values. OpenAI believes that AI can help to solve some of the world's most pressing problems, such as climate change, disease, inequality, and poverty. The organization is committed to advancing research and development in AI while ensuring that it is used ethically and responsibly."
```

### Streaming

When a function that takes a single `String` as an argument is passed in the `streamcallback` argument, a request will be made in
in streaming mode. The `streamcallback` callback will be called on every line of the streamed response. Here we use a callback
that prints out the current time to demonstrate how different parts of the response are received at different times. 

The response body will reflect the chunked nature of the response, so some reassembly will be required to recover the full
message returned by the API.

```julia
julia> CC = create_chat(key, "gpt-3.5-turbo", 
           [Dict("role" => "user", "content"=> "What continent is New York in? Two word answer.")],
       streamcallback = x->println(Dates.now()));
2023-03-27T12:34:50.428
2023-03-27T12:34:50.524
2023-03-27T12:34:50.524
2023-03-27T12:34:50.524
2023-03-27T12:34:50.545
2023-03-27T12:34:50.556
2023-03-27T12:34:50.556

julia> map(r->r["choices"][1]["delta"], CC.response)
5-element Vector{JSON3.Object{Base.CodeUnits{UInt8, SubString{String}}, SubArray{UInt64, 1, Vector{UInt64}, Tuple{UnitRange{Int64}}, true}}}:
 {
   "role": "assistant"
}
 {
   "content": "North"
}
 {
   "content": " America"
}
 {
   "content": "."
}
 {}
```
"""
function create_chat(api_key::String, model_id::String, messages; http_kwargs::NamedTuple=NamedTuple(), streamcallback=nothing, kwargs...)
    return openai_request("chat/completions", api_key; method="POST", http_kwargs=http_kwargs, model=model_id, messages=messages, streamcallback=streamcallback, kwargs...)
end
function create_chat(provider::AbstractOpenAIProvider, model_id::String, messages; http_kwargs::NamedTuple=NamedTuple(), streamcallback=nothing, kwargs...)
    return openai_request("chat/completions", provider; method="POST", http_kwargs=http_kwargs, model=model_id, messages=messages, streamcallback=streamcallback, kwargs...)
end

"""
Create edit

# Arguments:
- `api_key::String`: OpenAI API key
- `model_id::String`: Model id (e.g. "text-davinci-edit-001")
- `instruction::String`: The instruction that tells the model how to edit the prompt.
- `input::String` (optional): The input text to use as a starting point for the edit.
- `n::Int` (optional): How many edits to generate for the input and instruction.

# Keyword Arguments:
- `http_kwargs::NamedTuple` (optional): Keyword arguments to pass to HTTP.request.

For additional details about the endpoint, visit <https://platform.openai.com/docs/api-reference/edits>
"""
function create_edit(api_key::String, model_id::String, instruction::String; http_kwargs::NamedTuple=NamedTuple(), kwargs...)
    return openai_request("edits", api_key; method="POST", http_kwargs=http_kwargs, model=model_id, instruction, kwargs...)
end

"""
Create embeddings

# Arguments:
- `api_key::String`: OpenAI API key
- `input`: The input text to generate the embedding(s) for, as String or array of tokens.
    To get embeddings for multiple inputs in a single request, pass an array of strings
    or array of token arrays. Each input must not exceed 8192 tokens in length.
- `model_id::String`: Model id. Defaults to $DEFAULT_EMBEDDING_MODEL_ID.

# Keyword Arguments:
- `http_kwargs::NamedTuple`: Optional. Keyword arguments to pass to HTTP.request.

For additional details about the endpoint, visit <https://platform.openai.com/docs/api-reference/embeddings>
"""
function create_embeddings(api_key::String, input, model_id::String=DEFAULT_EMBEDDING_MODEL_ID; http_kwargs::NamedTuple=NamedTuple(), kwargs...)
    return openai_request("embeddings", api_key; method="POST", http_kwargs=http_kwargs, model=model_id, input, kwargs...)
end

"""
Create images

# Arguments: 
- `api_key::String`: OpenAI API key
- `prompt`: The input text to generate the image(s) for, as String or array of tokens.
- `n::Integer`: Optional. The number of images to generate. Must be between 1 and 10.
- `size::String`: Optional. Defaults to 1024x1024. The size of the generated images. Must be one of 256x256, 512x512, or 1024x1024.

# Keyword Arguments:
- `http_kwargs::NamedTuple`: Optional. Keyword arguments to pass to HTTP.request.
- `response_format::String`: Optional. Defaults to "url". The format of the response. Must be one of "url" or "b64_json".

For additional details about the endpoint, visit <https://platform.openai.com/docs/api-reference/images/create>

# once the request is made, 
download like this: 
`download(r.response["data"][begin]["url"], "image.png")`
"""
function create_images(api_key::String, prompt, n::Integer=1, size::String="256x256"; http_kwargs::NamedTuple=NamedTuple(), kwargs...)
    return openai_request("images/generations", api_key; method="POST", http_kwargs=http_kwargs, prompt, kwargs...)
end

# api usage status

"""
    get_usage_status(provider::OpenAIProvider; numofdays::Int=99)

    NOTE: currently this endpoint can only be used from the browser. See https://github.com/JuliaML/OpenAI.jl/issues/46

    Get usage status for the last `numofdays` days.

# Arguments:
- `provider::OpenAIProvider`: OpenAI provider object.
- `numofdays::Int`: Optional. Defaults to 99. The number of days to get usage status for.
   Note that the maximum `numofdays` is 99.

# Returns:
- `quota`: The total quota for the subscription.(unit: USD)
- `usage`: The total usage for the subscription.(unit: USD)
- `daily_costs`: The daily costs for the subscription.

Each element of `daily_costs` looks like this:
```
{
    "timestamp": 1681171200,
   "line_items": [
                   {
                      "name": "Instruct models",
                      "cost": 0
                   },
                   {
                      "name": "Chat models",
                      "cost": 0
                   },
                   {
                      "name": "GPT-4",
                      "cost": 0
                   },
                   {
                      "name": "Fine-tuned models",
                      "cost": 0
                   },
                   {
                      "name": "Embedding models",
                      "cost": 0
                   },
                   {
                      "name": "Image models",
                      "cost": 0
                   },
                   {
                      "name": "Audio models",
                      "cost": 0
                   }
                 ]
}
```
"""
function get_usage_status(provider::OpenAIProvider; numofdays::Int=99)
    (; base_url, api_key) = provider
    isempty(api_key) && throw(ArgumentError("api_key cannot be empty"))
    numofdays > 99 && throw(ArgumentError("numofdays cannot be greater than 99"))

    # Get total quota from subscription_url
    subscription_url = "$base_url/dashboard/billing/subscription"
    subscrip = HTTP.get(subscription_url, headers=auth_header(provider))
    resp = OpenAIResponse(subscrip.status, JSON3.read(subscrip.body))
    # TODO: catch error
    quota = resp.response.hard_limit_usd

    # Get usage status from billing_url
    start_date = today()
    end_date = today() + Day(numofdays)
    billing_url = "$base_url/dashboard/billing/usage?start_date=$(start_date)&end_date=$(end_date)"
    billing = HTTP.get(billing_url, headers=auth_header(provider))
    resp = OpenAIResponse(billing.status, JSON3.read(billing.body))
    usage = resp.response.total_usage / 100
    daily_costs = resp.response.daily_costs
    return (; quota, usage, daily_costs)
end

export OpenAIResponse
export list_models
export retrieve_model
export create_chat
export create_completion
export create_edit
export create_embeddings
export create_images
export get_usage_status

end # module
