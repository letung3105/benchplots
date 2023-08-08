using CairoMakie, Cascadia, DataFrames, Gumbo, Statistics

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
    lang_addresses = eachmatch(sel"body aside:first-of-type ul > li > a", home_html.root)
    map(parse_address_simple, lang_addresses)
end

function crawl_problems_from_home_page(home_html::HTMLDocument)::Vector{NamedPath}
    problem_addresses = eachmatch(sel"body aside:last-of-type ul > li > a", home_html.root)
    map(parse_address_simple, problem_addresses)
end

function crawl_benchmarks_from_problem_page(problem_html::HTMLDocument)
    input_size_regex = r"Input: (.+)"
    benchmarks = Vector{Dict{String,String}}()
    for container in eachmatch(sel"body aside:first-of-type + div > div:last-of-type > div", problem_html.root)
        titles = eachmatch(sel"h3", container)
        inputs = match(input_size_regex, parse_text(titles[1]))
        tables = eachmatch(sel"table", container)
        table_rows = eachmatch(sel"tbody > tr", tables[1])
        table_head = eachmatch(sel"tr > th", tables[1])
        # Go through each benchmark
        for table_row in table_rows
            benchmark = Dict{String,String}()
            benchmark["input"] = inputs[1]
            table_data = eachmatch(sel"td", table_row)
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
    parse_milliseconds = x -> parse_number_from_pattern(Float32, r"((\d+)(\.\d+)?)ms", x)
    parse_megabytes = x -> parse_number_from_pattern(Float32, r"((\d+)(\.\d+)?)MB", x)

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
    df_overview = sort!(
        combine(
            groupby(df_problem, "lang"),
            metric => mean,
            nrow,
            renamecols=false
        ),
        metric,
    )

    languages = df_overview[!, "lang"]
    language_ids = Dict{String,Int32}()
    for lang in languages
        if !haskey(language_ids, lang)
            language_ids[lang] = length(language_ids)
        end
    end

    xs = df_problem[!, "lang"] .|> lang -> language_ids[lang]
    ys = df_problem[!, metric]

    language_counts = string.(df_overview[!, "nrow"])
    xticks = map(
        (lang, count)::Tuple{String,String} -> "$lang (n=$count)",
        zip(languages, language_counts)
    )

    figure = Figure()
    axis = Axis(
        figure[1, 1],
        title=df_problem[1, "problem"] * " " * df_problem[1, "input"],
        ylabel=metric,
        xlabel="Languages",
        xticks=(0:length(xticks)-1, xticks),
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
    img_cpu_paths = Vector{String}()
    img_mem_paths = Vector{String}()
    for k in keys(groupby(df_benchmarks, ["problem", "input"]))
        problem = replace(k.problem, isspace => "-")
        input = replace(k.input, isspace => "-")
        path_cpu = "./images/cpu/$(problem)_$(input).png"
        path_mem = "./images/mem/$(problem)_$(input).png"
        save(path_cpu, plot_benchmark(df_benchmarks, k.problem, k.input, "time"))
        save(path_mem, plot_benchmark(df_benchmarks, k.problem, k.input, "peak-mem"))
        push!(img_cpu_paths, path_cpu)
        push!(img_mem_paths, path_mem)
    end
    md_cpu_images = join(map(x -> "![$x]($x)", img_cpu_paths), "\n")
    md_mem_images = join(map(x -> "![$x]($x)", img_mem_paths), "\n")
    md_content = join(
        [
            "# Benchplots",
            "Plots were made using data crawled from [Programming Language and Compiler Benchmarks](https://programming-language-benchmarks.vercel.app/zig)",
            "## cpu",
            md_cpu_images,
            "## mem",
            md_mem_images
        ],
        "\n"
    )
    write("README.md", md_content)
end
