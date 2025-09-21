![Tournament banner image](assets/banner.png)
# We're In Deep Ship: Battleship Tournament!
Pit AI's in a battle to the death so they can't take our jobs.

## How to enter
Submit a pull request adding your entry to `entries/`. See the example `entries/random-ralph`.
Your entry should consist of:
- A Battleship solution
- An entry name
- A 300x300 jpg or png image
- A short sound effect
- An entry.zon file, indexing the above info

## Tournament Rules
- Every contestant pair will play 1 round of 3 games.
- Each game gives +10 point for a win -10 for a loss. The contestant with the most points wins the tournament.
- Contestant programs will be invoked fresh each round.
- You can use any programming language but no third party libraries. You're limited to the standard library of your language.
- All programs will run on the same hardware. Each will be limited to 5GiB of RAM and 2 CPU cores.
- Programs have 5 seconds start up time and 1 second for each move.
    - Each time a program exceeds a time limit it will be penalized 1 point

## Battleship Rules
We will use the standard battleship rules.
- The game is played on a 10x10 grid.
- Ships are placed horizontally or vertically within the grid without overlapping.
- The ship types are:
    - Carrier (5)
    - Battleship (4)
    - Cruiser (3)
    - Submarine (3)
    - Destroyer (2)
- Players fire on one square per turn. You know if each shot was a hit or miss. You also know if a shot sunk a ship and which ship was sunk.
- The first player to sink all the opponent's ships wins the game.

## Technical Details
`src/` if this repo contains the Referee, which will be responsible for orchestrating the contestants. Contestant programs will communicate with the Referee over stdin/stdout via a custom text based protocol.

Describing the full protocol is a TODO, but messages will be sent from the Referee to a program over stdin and the program will reply by writing to stdout. Here is an example of how it might look:
| Time | STDIN             | STDOUT      |
| -----| ----------------- | ----------- |
| 0    | round-start       | round-start |
| 1    | game-start        | game-start  |
| 2    | place-ships       | place-ships;2;horizontal;A9;3;vertical;B4;3;horizontal;C2;4;horizontal;C3;5;horizontal;C4 |
| 3    | turn              | turn;B4     |
| 5    | result;you;hit;B4 | [no-reply]  |
| 6    | result;enemy;miss;C9 | [no-reply] |
