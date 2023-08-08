using CairoMakie, Cascadia, DataFrames, Gumbo, Statistics, Unitful

import Dates, HTTP

const NamedPath = @NamedTuple{name::String, path::String}

function benchmark_game_html(path::String; host="programming-language-benchmarks.vercel.app")::HTMLDocument
    uri = HTTP.URI(path, scheme="https", host=host)
    response = HTTP.get(uri)
    @assert response.status == 200
    response_body = String(response.body)
    parsehtml(response_body)
end

function parse_text(elem::HTMLElement)::String
    elem_children = children(elem)
    parse_text(elem_children[1])
end

function parse_text(elem::HTMLText)::String
    strip(elem.text)
end

function parse_address_simple(elem::HTMLElement)::NamedPath
    name = parse_text(elem)
    path = strip(elem.attributes["href"])
    (name=name, path=path)
end

function parse_number_from_pattern(type::Type{T}, pattern::Regex, input::String)::T where {T}
    matched = match(pattern, input)
    parse(type, matched[1])
end

function crawl_languages_from_home_page(home_html::HTMLDocument)::Vector{NamedPath}
    selector = sel"body aside:first-of-type ul > li > a"
    lang_addresses = eachmatch(selector, home_html.root)
    map(parse_address_simple, lang_addresses)
end

function crawl_problems_from_home_page(home_html::HTMLDocument)::Vector{NamedPath}
    selector = sel"body aside:last-of-type ul > li > a"
    problem_addresses = eachmatch(selector, home_html.root)
    map(parse_address_simple, problem_addresses)
end

function crawl_benchmarks_from_problem_page(problem_html::HTMLDocument)
    selector_benchmarks_container = sel"body aside:first-of-type + div > div:last-of-type > div"
    selector_benchmark_title = sel"h3"
    selector_benchmark_table = sel"table"
    selector_benchmark_table_head = sel"tr > th"
    selector_benchmark_table_rows = sel"tbody > tr"
    selector_benchmark_table_data = sel"td"
    input_size_regex = r"Input: (.+)"
    benchmarks = Vector{Dict{String,String}}()
    for container in eachmatch(selector_benchmarks_container, problem_html.root)
        titles = eachmatch(selector_benchmark_title, container)
        inputs = match(input_size_regex, parse_text(titles[1]))
        tables = eachmatch(selector_benchmark_table, container)
        table_rows = eachmatch(selector_benchmark_table_rows, tables[1])
        table_head = eachmatch(selector_benchmark_table_head, tables[1])
        # Go through each benchmark
        for table_row in table_rows
            benchmark = Dict{String,String}()
            benchmark["input"] = inputs[1]
            table_data = eachmatch(selector_benchmark_table_data, table_row)
            if (length(table_data) != length(table_head))
                continue
            end
            # Go through each column
            for (head, data) in zip(table_head, table_data)
                col_name = parse_text(head)
                col_data = parse_text(data)
                benchmark[col_name] = col_data
            end
            push!(benchmarks, benchmark)
        end
    end
    benchmarks
end

function get_benchmarks_dataframe(benchmarks::Vector{Dict{String,String}})::DataFrame
    pattern_milliseconds = r"((\d+)(\.\d+)?)ms"
    pattern_megabytes = r"((\d+)(\.\d+)?)MB"

    parse_milliseconds = x -> parse_number_from_pattern(Float32, pattern_milliseconds, x)
    parse_megabytes = x -> parse_number_from_pattern(Float32, pattern_megabytes, x)

    df = DataFrame(map(
        col_name -> col_name => map(result -> get(result, col_name, ""), benchmarks),
        Iterators.flatmap(result -> keys(result), benchmarks) |> unique
    ))
    subset!(
        df,
        "time" => x -> x .!= "timeout",
        "time(sys)" => x -> x .!= "timeout",
        "time(user)" => x -> x .!= "timeout"
    )
    transform!(
        df,
        "time" => x -> parse_milliseconds.(x),
        "time(sys)" => x -> parse_milliseconds.(x),
        "time(user)" => x -> parse_milliseconds.(x),
        "stddev" => x -> parse_milliseconds.(x),
        "peak-mem" => x -> parse_megabytes.(x),
        renamecols=false
    )
end

function plot_benchmark(df_benchmarks::DataFrame, problem::String, input::String, metric::String)::Figure
    df_problem = subset(
        df_benchmarks,
        "problem" => x -> x .== problem,
        "input" => x -> x .== input,
    )
    df_mean = sort!(
        combine(
            groupby(df_problem, "lang"),
            metric => mean,
            renamecols=false
        ),
        metric,
    )

    languages = df_mean[!, "lang"] |> unique
    language_ids = Dict{String,Int32}()
    for lang in languages
        if !haskey(language_ids, lang)
            language_ids[lang] = length(language_ids)
        end
    end

    xs = df_problem[!, "lang"] .|> lang -> language_ids[lang]
    ys = df_problem[!, metric]

    figure = Figure()
    axis = Axis(
        figure[1, 1],
        title=df_problem[1, "problem"] * " " * df_problem[1, "input"],
        ylabel=metric,
        xlabel="Languages",
        xticks=(0:length(languages)-1, languages),
        xticklabelrotation=45.0
    )
    boxplot!(axis, xs, ys)
    figure
end

let df_benchmarks = (
        Iterators.flatmap(
            problem -> map(
                benchmark -> setindex!(benchmark, problem.name, "problem"),
                benchmark_game_html(problem.path) |> crawl_benchmarks_from_problem_page
            ),
            benchmark_game_html("/") |> crawl_problems_from_home_page
        )
        |> collect
        |> get_benchmarks_dataframe
    )
    for (problem, input) in keys(groupby(df_benchmarks, ["problem", "input"]))
        save("./images/cpu/$(problem)_$input.png", plot_benchmark(df_benchmarks, problem, input, "time"))
        save("./images/mem/$(problem)_$input.png", plot_benchmark(df_benchmarks, problem, input, "peak-mem"))
    end
end
