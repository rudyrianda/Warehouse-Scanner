using System;
using System.Data.SqlClient;
using System.Linq;

class Program
{
    static void Main()
    {
        // We will just do the string matching logic exactly as C# does it
        string input = "123%123";
        string prefix = "123";

        // simulating LIKE in SQL
        Console.WriteLine($"Input: {input}");
        Console.WriteLine($"Prefix: {prefix}");
        
        // This is what the SQL does: input LIKE prefix + '%'
        // Which means input starts with prefix
        bool startsWith = input.StartsWith(prefix);
        Console.WriteLine($"SQL LIKE matching (StartsWith): {startsWith}");

        // Now let's test if input is "123"
        string input2 = "123";
        bool startsWith2 = input2.StartsWith(prefix);
        Console.WriteLine($"Input 2: {input2}");
        Console.WriteLine($"SQL LIKE matching (StartsWith): {startsWith2}");
        
        // What if they scan %123%123 in D3?
        string input3 = "123%123";
        bool startsWith3 = input3.StartsWith(prefix);
        Console.WriteLine($"Input 3: {input3}");
        Console.WriteLine($"SQL LIKE matching (StartsWith): {startsWith3}");
    }
}
